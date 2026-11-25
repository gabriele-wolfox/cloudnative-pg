# CloudNativePG + pgvector + LLM: RAG POC

A proof of concept to ask an LLM questions about **your own data** stored in
PostgreSQL. CloudNativePG runs PostgreSQL with pgvector, the data is chunked and
embedded into a vector table, and each question is answered by an LLM using
only the most relevant chunks as context (Retrieval Augmented Generation).

```
  your laptop                         Kubernetes (namespace llm-d)
 ┌───────────────────┐   port-forward  ┌──────────────────────────────────────┐
 │ files / tables    │                 │ PostgreSQL + pgvector (CloudNativePG)│
 │        │          │  ─────────────► │  table rag_chunks: text + embedding  │
 │        ▼          │                 ├──────────────────────────────────────┤
 │ demo-app/rag.py   │  ─────────────► │  model server, OpenAI-compatible API │
 │ ingest / ask      │                 │   - embeddings: nomic-embed-text     │
 └───────────────────┘                 │   - chat: qwen2.5:1.5b (Ollama, CPU) │
                                       │     or vLLM / llm-d on GPU           │
                                       └──────────────────────────────────────┘
```

How a question is answered:

1. the question is embedded with the same model used for the documents
2. pgvector returns the `k` closest chunks (cosine distance, HNSW index)
3. the chunks are sent to the chat model as numbered context, with the
   instruction to answer only from them and cite the excerpts used
4. the answer is printed together with its sources

`rag.py` only speaks the OpenAI-compatible API (`/v1/embeddings`,
`/v1/chat/completions`), so the chat model can be anything that exposes it:
the local Ollama, vLLM, an llm-d inference gateway, or a hosted endpoint.

## Prerequisites

- Docker, [Kind](https://kind.sigs.k8s.io/), `kubectl`
- Python 3.9+
- ~6 GB of free RAM and ~5 GB of disk for the images and models

No GPU is needed for the local setup: models run on CPU. Answers take a few
seconds to a few tens of seconds, depending on your machine.

## Quick start (local, Kind)

```bash
cd hack/llm-d
./setup.sh      # Kind cluster + CloudNativePG + PostgreSQL/pgvector + Ollama
./test.sh       # ingests demo-app/sample-data and asks a few questions
```

The first `setup.sh` run downloads the model server image and the models, so it
can take several minutes.

## Using your own data

Open the tunnels in a separate terminal and leave it running:

```bash
./port-forward.sh          # PostgreSQL on localhost:15432, Ollama on :11434
```

Then, in your working terminal:

```bash
source ./env.sh            # DATABASE_URL (password read from the vectordb-app secret), EMBED_URL, LLM_URL
python3 -m venv .venv && . .venv/bin/activate
pip install -r demo-app/requirements.txt

./demo-app/rag.py init     # creates the rag_chunks table (sized for the embedding model)
```

### From files

Any UTF-8 text file works (`.md`, `.txt`, `.rst`, `.adoc`, `.csv`, `.json`,
`.yaml`, `.html`, `.sql`). Directories are scanned recursively.

```bash
./demo-app/rag.py ingest-files ~/docs/handbook ./notes.md
```

Re-ingesting a file replaces its previous chunks, so you can run it again after
editing your data. PDFs and Office documents need to be converted to text first
(e.g. `pdftotext`, `pandoc`).

### From tables already in PostgreSQL

Load your data into `ragdb` the way you prefer, for example:

```bash
psql "$DATABASE_URL" -f my_dump.sql
# or
pg_restore -d "$DATABASE_URL" --no-owner my_dump.dump
# or
psql "$DATABASE_URL" -c "\copy tickets FROM 'tickets.csv' CSV HEADER"
```

Then ingest it with a query returning two columns, `(source, content)`. The
`source` identifies the row in the answers' citations; `content` is the text to
make searchable. Build it from as many columns as you need:

```bash
./demo-app/rag.py ingest-sql "
  SELECT 'ticket-' || id,
         'Title: ' || title || E'\n' || 'Product: ' || product || E'\n\n' || body
  FROM tickets"
```

### Asking questions

```bash
./demo-app/rag.py ask "How do we handle a failover during an upgrade?"
./demo-app/rag.py ask -k 8 --show-context "..."   # more chunks, and print what the LLM sees
./demo-app/rag.py chat                            # interactive loop
./demo-app/rag.py stats                           # what has been ingested
```

Example output:

```
pgvector supports two approximate index types: IVFFlat, which partitions
vectors into lists, and HNSW, which builds a multi-layer graph [1].

Sources:
  [1] demo-app/sample-data/pgvector.md#0  (similarity 0.771)
  [2] demo-app/sample-data/cloudnative-pg.md#0  (similarity 0.512)
  ...
```

## Configuration

All settings are environment variables (`env.sh` sets sensible defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | set by `env.sh` | PostgreSQL connection string |
| `RAG_TABLE` | `rag_chunks` | Table for chunks; use different tables to keep datasets apart |
| `EMBED_URL` | `http://localhost:11434` | OpenAI-compatible embeddings endpoint |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding model |
| `LLM_URL` | `http://localhost:11434` (`:8000` if vLLM is deployed) | OpenAI-compatible chat endpoint |
| `LLM_MODEL` | first chat model the endpoint lists | Chat model |
| `LLM_API_KEY` | (empty) | Bearer token, for hosted endpoints |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `1200` / `200` | Chunk size and overlap, in characters |

### Better answers

The default chat model (`qwen2.5:1.5b`) is chosen to run on any laptop, not for
quality. To try a larger one, change `MODELS` in `ollama.yaml` (e.g.
`nomic-embed-text llama3.1:8b` or `qwen2.5:7b`), then:

```bash
kubectl apply -f ollama.yaml
kubectl rollout status deployment/ollama -n llm-d --timeout=30m
export LLM_MODEL=qwen2.5:7b
```

Changing `EMBED_MODEL` changes the vector size: run `rag.py init --reset` and
ingest the data again.

## Running on GKE with a GPU (vLLM)

For a faster and bigger chat model, `gke-setup.sh` creates a GKE cluster with a
T4 GPU and deploys the same PostgreSQL cluster, vLLM serving
`microsoft/Phi-3-mini-4k-instruct` (`llm-d-gke.yaml`) and Ollama for the
embeddings. Google Cloud offers a $300 free trial, which is enough for this.

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
./gke-setup.sh
kubectl logs -f deployment/llm-d -n llm-d    # model download takes 5-10 min
./test.sh                                    # env.sh picks vLLM automatically
```

| Variable | Default | Description |
|----------|---------|-------------|
| `GCP_PROJECT_ID` | (from gcloud) | Your GCP project |
| `GCP_ZONE` | us-central1-a | Zone for the cluster |
| `GPU_TYPE` | nvidia-tesla-t4 | GPU type (t4, l4, a100) |
| `GPU_COUNT` | 1 | Number of GPUs |

**Estimated cost**: ~$0.50-1.00/hour. Delete everything when you are done:

```bash
./gke-cleanup.sh
```

For the full llm-d stack (inference gateway, prefix-cache aware routing), see
the [llm-d documentation](https://github.com/llm-d/llm-d), then point `LLM_URL`
at its gateway.

## Cleanup

```bash
./cleanup.sh    # deletes the Kind cluster
```

## Troubleshooting

```bash
kubectl get cluster vectordb -n llm-d                 # PostgreSQL status
kubectl logs vectordb-1 -n llm-d                      # PostgreSQL logs
kubectl logs deploy/ollama -n llm-d -c pull-models    # model download progress
kubectl exec -it vectordb-1 -n llm-d -- psql ragdb    # psql as superuser
```

- *Cannot reach http://localhost:…*: `./port-forward.sh` is not running.
- *Answers say "I don't know"*: check what is retrieved with `--show-context`;
  try a higher `-k`, or a smaller `CHUNK_SIZE` for dense data.
- *`expected N dimensions, not M`*: the embedding model changed since `init`;
  run `rag.py init --reset` and ingest again.

## Files

```
hack/llm-d/
├── setup.sh / cleanup.sh       # local Kind environment
├── gke-setup.sh / gke-cleanup.sh
├── port-forward.sh             # PostgreSQL + model server on localhost
├── env.sh                      # connection settings for rag.py (source it)
├── test.sh                     # end-to-end test
├── kind-config.yaml
├── postgres-cluster.yaml       # CloudNativePG cluster with pgvector
├── ollama.yaml                 # CPU embeddings + chat model
├── llm-d-gke.yaml              # vLLM on GPU (GKE)
└── demo-app/
    ├── rag.py                  # ingest + ask CLI
    ├── requirements.txt
    └── sample-data/            # small demo corpus
```
