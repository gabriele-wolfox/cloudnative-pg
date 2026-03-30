# CloudNativePG + llm-d POC

A proof-of-concept demonstrating how to use CloudNativePG with pgvector to provide
vector storage for RAG (Retrieval Augmented Generation) workloads with llm-d.

## Overview

This POC shows:
- PostgreSQL cluster managed by CloudNativePG with pgvector extension
- Mock llm-d inference service (replace with real llm-d for production)
- RAG pattern: store document embeddings, retrieve similar docs, augment LLM prompts

```
┌─────────────────────────────────────────────────────────────┐
│                     Kind Cluster                            │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │              │    │              │    │              │  │
│  │  PostgreSQL  │◄───│   RAG App    │───►│   llm-d      │  │
│  │  + pgvector  │    │              │    │   (mock)     │  │
│  │              │    │              │    │              │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│        ▲                                                    │
│        │                                                    │
│  CloudNativePG                                              │
│    Operator                                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.28+
- [Helm](https://helm.sh/docs/intro/install/) v3.12+

## Quick Start

### 1. Setup

```bash
# Create cluster and deploy all components
./setup.sh
```

This will:
1. Create a Kind cluster named `llm-d-poc`
2. Install CloudNativePG operator
3. Deploy PostgreSQL cluster with pgvector
4. Deploy mock llm-d service

### 2. Test

```bash
# Run the test suite including RAG demo
./test.sh
```

### 3. Explore

Connect to PostgreSQL directly:

```bash
kubectl exec -it vectordb-1 -n llm-d -- psql -U raguser -d ragdb
```

Try some vector operations:

```sql
-- Check pgvector extension
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';

-- Create a test table
CREATE TABLE items (id SERIAL PRIMARY KEY, embedding vector(3));

-- Insert vectors
INSERT INTO items (embedding) VALUES ('[1,2,3]'), ('[4,5,6]'), ('[1,2,4]');

-- Find similar vectors (cosine distance)
SELECT id, embedding, embedding <=> '[1,2,3]' AS distance
FROM items ORDER BY distance LIMIT 2;
```

### 4. Cleanup

```bash
./cleanup.sh
```

## Running on GKE with Real GPU (Free Trial)

Google Cloud offers a **$300 free trial** for 90 days - enough to test with real GPUs.

### Prerequisites

1. Sign up at https://cloud.google.com/free
2. Install [gcloud CLI](https://cloud.google.com/sdk/docs/install)
3. Authenticate: `gcloud auth login`
4. Set project: `gcloud config set project YOUR_PROJECT_ID`

### Deploy to GKE

```bash
# Create GKE cluster with T4 GPU and deploy everything
./gke-setup.sh

# Monitor llm-d startup (model download takes 5-10 min)
kubectl logs -f deployment/llm-d -n llm-d

# Test the deployment
kubectl port-forward svc/llm-d -n llm-d 8000:8000
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is PostgreSQL?", "max_tokens": 100}'
```

### Cost & Cleanup

**Estimated cost**: ~$0.50-1.00/hour (T4 GPU + GKE nodes)

```bash
# IMPORTANT: Delete when done to avoid charges!
./gke-cleanup.sh
```

### Configuration

Environment variables for `gke-setup.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `GCP_PROJECT_ID` | (from gcloud) | Your GCP project |
| `GCP_ZONE` | us-central1-a | Zone for the cluster |
| `GPU_TYPE` | nvidia-tesla-t4 | GPU type (t4, l4, a100) |
| `GPU_COUNT` | 1 | Number of GPUs |

## Using Real llm-d (Advanced)

For production llm-d with full inference gateway features:

```bash
# Add llm-d helm repo
helm install llm-d oci://ghcr.io/llm-d/llm-d-deployer/llm-d \
  --namespace llm-d \
  --set model.name=meta-llama/Llama-3.2-1B \
  --set resources.gpu=1
```

See [llm-d documentation](https://github.com/llm-d/llm-d) for full deployment options.

## Using Real Embeddings

The demo uses mock embeddings. For production RAG:

1. Use an embedding model (e.g., sentence-transformers, OpenAI embeddings)
2. Embed documents before storing in pgvector
3. Embed queries before similarity search

Example with sentence-transformers:

```python
from sentence_transformers import SentenceTransformer

model = SentenceTransformer('all-MiniLM-L6-v2')

# Embed documents
doc_embedding = model.encode("Your document text here")

# Store in pgvector
cursor.execute(
    "INSERT INTO documents (content, embedding) VALUES (%s, %s)",
    (content, doc_embedding.tolist())
)

# Query
query_embedding = model.encode("Your question here")
cursor.execute("""
    SELECT content FROM documents
    ORDER BY embedding <=> %s::vector
    LIMIT 5
""", (query_embedding.tolist(),))
```

## Project Structure

```
hack/llm-d/
├── README.md              # This file
├── kind-config.yaml       # Kind cluster configuration
├── setup.sh               # Local Kind setup script
├── test.sh                # Test script
├── cleanup.sh             # Local cleanup script
├── postgres-cluster.yaml  # CloudNativePG cluster with pgvector
├── llm-d-mock.yaml        # Mock llm-d (for local/CPU testing)
├── gke-setup.sh           # GKE setup with real GPU
├── gke-cleanup.sh         # GKE cleanup (avoid charges!)
├── llm-d-gke.yaml         # Real vLLM deployment for GKE
└── demo-app/
    └── rag-demo.py        # RAG demonstration script
```

## Troubleshooting

### PostgreSQL cluster not ready

```bash
# Check cluster status
kubectl get cluster vectordb -n llm-d -o yaml

# Check pod logs
kubectl logs vectordb-1 -n llm-d
```

### pgvector not available

The POC uses PostgreSQL 17 which has pgvector available via `CREATE EXTENSION`.
If using older versions, you may need to use the image volume extensions feature
with PostgreSQL 18+ (see `docs/src/imagevolume_extensions.md`).

### Connection issues

```bash
# Port-forward PostgreSQL
kubectl port-forward svc/vectordb-rw -n llm-d 5432:5432

# Connect locally
psql -h localhost -U raguser -d ragdb
```

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [llm-d GitHub](https://github.com/llm-d/llm-d)
- [RAG Pattern](https://www.promptingguide.ai/techniques/rag)
