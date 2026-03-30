# Building a RAG Stack on Kubernetes with CloudNativePG, pgvector, and llm-d

Modern AI applications increasingly rely on Retrieval Augmented Generation (RAG) to provide LLMs with relevant context from your own data. This article walks through building a complete RAG stack on Kubernetes using three powerful open-source projects:

- **CloudNativePG** - Kubernetes operator for PostgreSQL
- **pgvector** - Vector similarity search extension for PostgreSQL
- **llm-d** - High-performance LLM inference serving stack

By the end, you'll have a working proof-of-concept running locally in Kind that demonstrates the full RAG pattern: storing document embeddings in PostgreSQL, retrieving similar documents via vector search, and augmenting LLM prompts with the retrieved context.

## Why This Stack?

### The RAG Pattern

Large Language Models are powerful but have limitations: they can hallucinate, their knowledge has a cutoff date, and they don't know about your private data. RAG solves this by:

1. Converting your documents into vector embeddings
2. Storing those embeddings in a vector database
3. When a user asks a question, finding similar documents via vector search
4. Passing those documents as context to the LLM

This grounds the LLM's responses in your actual data.

### Why PostgreSQL for Vectors?

You might wonder: why not use a dedicated vector database like Pinecone or Milvus? PostgreSQL with pgvector offers compelling advantages:

- **Simplicity** - One database for both your application data and vectors
- **ACID transactions** - Vector updates are transactional with your other data
- **Mature ecosystem** - Backups, replication, monitoring all work as expected
- **Cost effective** - No additional database to manage and pay for
- **SQL interface** - Query vectors alongside relational data

### Why CloudNativePG?

Running PostgreSQL on Kubernetes used to be controversial. CloudNativePG changes that by providing:

- Declarative cluster management via CRDs
- Automated failover and high availability
- Integrated backup and recovery
- Native Kubernetes integration (services, secrets, RBAC)
- Support for extensions like pgvector

### Why llm-d?

llm-d is a Kubernetes-native inference stack that provides:

- High-performance serving via vLLM
- Intelligent load balancing with prefix-cache awareness
- Production-grade infrastructure management
- OpenAI-compatible API

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                      │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │              │    │              │    │              │  │
│  │  PostgreSQL  │◄───│   RAG App    │───►│   llm-d      │  │
│  │  + pgvector  │    │              │    │   (vLLM)     │  │
│  │              │    │              │    │              │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│        ▲                    │                    │          │
│        │                    │                    │          │
│  CloudNativePG         1. Embed query      3. Generate     │
│    Operator            2. Vector search       response     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

The flow is:
1. User sends a question to the RAG application
2. Application embeds the question and searches pgvector for similar documents
3. Retrieved documents are added to the prompt as context
4. llm-d generates a response grounded in the retrieved context

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/) - Kubernetes in Docker
- [kubectl](https://kubernetes.io/docs/tasks/tools/) - Kubernetes CLI
- [Helm](https://helm.sh/) - Kubernetes package manager

## Step 1: Create the Kind Cluster

First, create a local Kubernetes cluster:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: llm-d-poc
nodes:
  - role: control-plane
  - role: worker
```

```bash
kind create cluster --config kind-config.yaml
```

## Step 2: Install CloudNativePG

Deploy the CloudNativePG operator:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml

# Wait for the operator
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=120s
```

## Step 3: Deploy PostgreSQL with pgvector

Create a PostgreSQL cluster with the vector extension:

```yaml
# postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: vectordb
  namespace: llm-d
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.4-bookworm

  storage:
    size: 2Gi

  bootstrap:
    initdb:
      database: ragdb
      owner: raguser
      postInitSQL:
        - CREATE EXTENSION IF NOT EXISTS vector;

  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "100"
```

```bash
kubectl create namespace llm-d
kubectl apply -f postgres-cluster.yaml

# Wait for the cluster
kubectl wait --for=condition=Ready cluster/vectordb -n llm-d --timeout=300s
```

## Step 4: Deploy the LLM Service

For local testing without a GPU, we use a mock service that implements the OpenAI API:

```yaml
# llm-d-mock.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-d-mock
  namespace: llm-d
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llm-d-mock
  template:
    metadata:
      labels:
        app: llm-d-mock
    spec:
      containers:
        - name: llm-mock
          image: python:3.11-slim
          command:
            - python
            - -c
            - |
              from http.server import HTTPServer, BaseHTTPRequestHandler
              import json

              class LLMHandler(BaseHTTPRequestHandler):
                  def do_POST(self):
                      content_length = int(self.headers.get('Content-Length', 0))
                      body = self.rfile.read(content_length).decode('utf-8')
                      request = json.loads(body) if body else {}
                      prompt = request.get('prompt', '')

                      response = {
                          "choices": [{
                              "text": f"[Response based on context] {prompt[:100]}..."
                          }]
                      }

                      self.send_response(200)
                      self.send_header('Content-Type', 'application/json')
                      self.end_headers()
                      self.wfile.write(json.dumps(response).encode())

              HTTPServer(('0.0.0.0', 8000), LLMHandler).serve_forever()
          ports:
            - containerPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: llm-d-mock
  namespace: llm-d
spec:
  selector:
    app: llm-d-mock
  ports:
    - port: 8000
```

For production with GPUs, replace this with actual vLLM or the full llm-d stack.

## Step 5: Test Vector Operations

Connect to PostgreSQL and verify pgvector is working:

```bash
kubectl exec -it vectordb-1 -n llm-d -- psql -U postgres -d ragdb
```

```sql
-- Verify extension
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';

-- Create a documents table
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    embedding vector(128)
);

-- Create an index for fast similarity search
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);

-- Insert sample documents (using mock embeddings)
INSERT INTO documents (content, embedding) VALUES
    ('CloudNativePG manages PostgreSQL on Kubernetes',
     '[0.1, 0.2, 0.3, ...]'::vector),  -- 128 dimensions
    ('pgvector enables vector similarity search',
     '[0.2, 0.3, 0.4, ...]'::vector);

-- Query similar documents
SELECT content, 1 - (embedding <=> query_vector) AS similarity
FROM documents
ORDER BY embedding <=> query_vector
LIMIT 5;
```

## Step 6: Implement the RAG Flow

Here's a simplified Python example of the RAG pattern:

```python
import psycopg
from sentence_transformers import SentenceTransformer

# Initialize embedding model
embedder = SentenceTransformer('all-MiniLM-L6-v2')

def store_document(conn, content: str):
    """Embed and store a document."""
    embedding = embedder.encode(content).tolist()
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO documents (content, embedding) VALUES (%s, %s)",
            (content, embedding)
        )
    conn.commit()

def search_similar(conn, query: str, limit: int = 3):
    """Find documents similar to the query."""
    query_embedding = embedder.encode(query).tolist()
    with conn.cursor() as cur:
        cur.execute("""
            SELECT content, 1 - (embedding <=> %s::vector) AS similarity
            FROM documents
            ORDER BY embedding <=> %s::vector
            LIMIT %s
        """, (query_embedding, query_embedding, limit))
        return cur.fetchall()

def rag_query(conn, question: str) -> str:
    """Complete RAG flow: retrieve context and query LLM."""
    # Step 1: Find relevant documents
    similar_docs = search_similar(conn, question)

    # Step 2: Build context
    context = "\n".join([doc[0] for doc in similar_docs])

    # Step 3: Query LLM with context
    prompt = f"""Context:
{context}

Question: {question}

Answer based on the context above:"""

    response = requests.post(
        "http://llm-d-mock:8000/v1/completions",
        json={"prompt": prompt, "max_tokens": 200}
    )
    return response.json()["choices"][0]["text"]
```

## Results

With everything deployed, you have a working RAG stack:

```
$ kubectl get pods -n llm-d
NAME                          READY   STATUS    RESTARTS   AGE
llm-d-mock-59cf97568d-z6q2b   1/1     Running   0          36m
vectordb-1                    1/1     Running   0          36m
```

Vector similarity search works correctly:

```
                    content                     |     similarity
------------------------------------------------+--------------------
 CloudNativePG manages PostgreSQL on Kubernetes |                  1
 pgvector enables vector similarity search      | 0.9938078912739567
 llm-d serves LLM inference at scale            | 0.9843740109529758
```

## Production Considerations

### GPU Support

For real LLM inference, you'll need GPUs. Options include:

- **GKE/EKS/AKS** with GPU node pools
- **On-premise** Kubernetes with NVIDIA GPU Operator

Replace the mock with vLLM:

```yaml
containers:
  - name: vllm
    image: vllm/vllm-openai:latest
    args:
      - "--model"
      - "microsoft/Phi-3-mini-4k-instruct"
    resources:
      limits:
        nvidia.com/gpu: "1"
```

### High Availability

Scale PostgreSQL for production:

```yaml
spec:
  instances: 3  # Primary + 2 replicas

  affinity:
    podAntiAffinityType: required  # Spread across nodes
```

### Embedding Models

For production embeddings, consider:

- **sentence-transformers** - Open source, self-hosted
- **OpenAI embeddings** - High quality, API-based
- **Cohere embeddings** - Good multilingual support

### Indexing Strategy

pgvector supports multiple index types:

- **HNSW** - Faster queries, more memory, better for most use cases
- **IVFFlat** - Slower queries, less memory, better for very large datasets

```sql
-- HNSW index (recommended)
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);

-- IVFFlat index (for large datasets)
CREATE INDEX ON documents USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);
```

## Cleanup

```bash
# Local Kind cluster
kind delete cluster --name llm-d-poc

# Or if using GKE (important to avoid charges!)
gcloud container clusters delete llm-d-poc --zone=us-central1-a
```

## Conclusion

This POC demonstrates that building a production-ready RAG stack on Kubernetes is straightforward with the right tools:

- **CloudNativePG** handles PostgreSQL lifecycle management
- **pgvector** provides fast vector similarity search within PostgreSQL
- **llm-d/vLLM** serves LLM inference at scale

The entire stack is declarative, Kubernetes-native, and can scale from a local Kind cluster to production GKE/EKS deployments.

## Resources

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [llm-d GitHub](https://github.com/llm-d/llm-d)
- [vLLM Documentation](https://docs.vllm.ai/)
- [POC Source Code](https://github.com/gabriele-wolfox/cloudnative-pg/tree/experiment-llm-d/hack/llm-d)
