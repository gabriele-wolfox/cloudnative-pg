#!/bin/bash
# Setup script for llm-d + CloudNativePG POC
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CNPG_VERSION="${CNPG_VERSION:-1.25.1}"

echo "=== llm-d + CloudNativePG POC Setup ==="

# Check prerequisites
command -v kind >/dev/null 2>&1 || { echo "kind is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting."; exit 1; }

# Step 1: Create Kind cluster
echo ""
echo "Step 1: Creating Kind cluster..."
if kind get clusters | grep -q "llm-d-poc"; then
    echo "Cluster 'llm-d-poc' already exists. Skipping creation."
else
    kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
fi

# Wait for cluster to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Step 2: Install CloudNativePG operator
echo ""
echo "Step 2: Installing CloudNativePG operator v${CNPG_VERSION}..."
kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"

# Wait for CNPG operator to be ready
echo "Waiting for CloudNativePG operator..."
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
    -n cnpg-system --timeout=120s

# Step 3: Create namespace and deploy PostgreSQL with pgvector
echo ""
echo "Step 3: Deploying PostgreSQL cluster with pgvector..."
kubectl create namespace llm-d --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/postgres-cluster.yaml"

# Wait for PostgreSQL cluster to be ready
echo "Waiting for PostgreSQL cluster to be ready (this may take a minute)..."
kubectl wait --for=condition=Ready cluster/vectordb -n llm-d --timeout=300s

# Step 4: Deploy llm-d (mock/lightweight version for POC)
echo ""
echo "Step 4: Deploying llm-d components..."
kubectl apply -f "${SCRIPT_DIR}/llm-d-mock.yaml"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "PostgreSQL connection info:"
echo "  Host: vectordb-rw.llm-d.svc.cluster.local"
echo "  Port: 5432"
echo "  Database: ragdb"
echo "  User: raguser"
echo ""
echo "To test the setup, run:"
echo "  ./test.sh"
echo ""
echo "To connect to PostgreSQL directly:"
echo "  kubectl exec -it vectordb-1 -n llm-d -- psql -U raguser -d ragdb"
