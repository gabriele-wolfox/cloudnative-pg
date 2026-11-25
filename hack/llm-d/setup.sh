#!/bin/bash
# Local (Kind, CPU-only) setup for the CloudNativePG + pgvector + LLM RAG POC
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CNPG_VERSION="${CNPG_VERSION:-1.30.2}"
NAMESPACE=llm-d

echo "=== CloudNativePG + LLM RAG POC Setup (Kind) ==="

for cmd in kind kubectl; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "${cmd} is required but not installed. Aborting."; exit 1; }
done

echo ""
echo "Step 1: Creating Kind cluster..."
if kind get clusters | grep -qx "llm-d-poc"; then
    echo "Cluster 'llm-d-poc' already exists. Skipping creation."
else
    kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
fi
kubectl config use-context kind-llm-d-poc
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo ""
echo "Step 2: Installing CloudNativePG operator v${CNPG_VERSION}..."
kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=180s

echo ""
echo "Step 3: Deploying PostgreSQL cluster with pgvector..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/postgres-cluster.yaml"

echo ""
echo "Step 4: Deploying the model server (embeddings + chat, CPU)..."
kubectl apply -f "${SCRIPT_DIR}/ollama.yaml"

echo ""
echo "Waiting for PostgreSQL..."
# The Cluster object may need a few seconds to get a status
until kubectl get cluster/vectordb -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q .; do sleep 2; done
kubectl wait --for=condition=Ready cluster/vectordb -n "${NAMESPACE}" --timeout=600s

echo "Waiting for the model server (first run downloads the models, can take several minutes)..."
kubectl rollout status deployment/ollama -n "${NAMESPACE}" --timeout=1800s

cat <<MSG

=== Setup Complete ===

Next steps:
  1. In another terminal:   ./port-forward.sh
  2. Then:                  source ./env.sh
                            pip install -r demo-app/requirements.txt
                            ./demo-app/rag.py init
                            ./demo-app/rag.py ingest-files demo-app/sample-data
                            ./demo-app/rag.py ask "What index types does pgvector support?"

Or run everything end-to-end with ./test.sh
MSG
