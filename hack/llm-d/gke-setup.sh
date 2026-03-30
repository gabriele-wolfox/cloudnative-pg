#!/bin/bash
# GKE Setup script for llm-d + CloudNativePG POC with GPU
# Requires: gcloud CLI authenticated with a project that has billing enabled
#
# Google Cloud Free Trial: $300 credit for 90 days
# Sign up at: https://cloud.google.com/free
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration - adjust as needed
PROJECT_ID="${GCP_PROJECT_ID:-}"
REGION="${GCP_REGION:-us-central1}"
ZONE="${GCP_ZONE:-us-central1-a}"
CLUSTER_NAME="${CLUSTER_NAME:-llm-d-poc}"
CNPG_VERSION="${CNPG_VERSION:-1.25.1}"

# GPU Configuration
# T4 is cheapest (~$0.35/hr), L4 is faster (~$0.70/hr)
GPU_TYPE="${GPU_TYPE:-nvidia-tesla-t4}"
GPU_COUNT="${GPU_COUNT:-1}"
GPU_MACHINE_TYPE="${GPU_MACHINE_TYPE:-n1-standard-4}"

echo "=== GKE Setup for llm-d + CloudNativePG POC ==="

# Check prerequisites
command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI is required. Install from: https://cloud.google.com/sdk/docs/install"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required."; exit 1; }

# Check project
if [ -z "${PROJECT_ID}" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    if [ -z "${PROJECT_ID}" ]; then
        echo "Error: No GCP project set. Run: gcloud config set project YOUR_PROJECT_ID"
        echo "Or set GCP_PROJECT_ID environment variable."
        exit 1
    fi
fi
echo "Using project: ${PROJECT_ID}"

# Enable required APIs
echo ""
echo "Step 1: Enabling required GCP APIs..."
gcloud services enable container.googleapis.com --project="${PROJECT_ID}"
gcloud services enable compute.googleapis.com --project="${PROJECT_ID}"

# Create GKE cluster with GPU node pool
echo ""
echo "Step 2: Creating GKE cluster (this takes 5-10 minutes)..."

# Check if cluster exists
if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
    # Create cluster with a default CPU node pool
    gcloud container clusters create "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --num-nodes=1 \
        --machine-type=e2-standard-2 \
        --disk-size=50GB \
        --enable-ip-alias \
        --workload-pool="${PROJECT_ID}.svc.id.goog"
fi

# Add GPU node pool
echo ""
echo "Step 3: Adding GPU node pool..."
if gcloud container node-pools describe gpu-pool --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "GPU node pool already exists. Skipping."
else
    gcloud container node-pools create gpu-pool \
        --project="${PROJECT_ID}" \
        --cluster="${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --num-nodes=1 \
        --machine-type="${GPU_MACHINE_TYPE}" \
        --accelerator="type=${GPU_TYPE},count=${GPU_COUNT}" \
        --disk-size=100GB
fi

# Get credentials
echo ""
echo "Step 4: Configuring kubectl..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

# Install NVIDIA GPU drivers (GKE daemonset)
echo ""
echo "Step 5: Installing NVIDIA GPU drivers..."
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded.yaml

# Wait for GPU driver to be ready
echo "Waiting for GPU driver installation (this may take 2-3 minutes)..."
sleep 30
kubectl wait --for=condition=Ready pods -l k8s-app=nvidia-driver-installer -n kube-system --timeout=300s 2>/dev/null || true

# Install CloudNativePG operator
echo ""
echo "Step 6: Installing CloudNativePG operator v${CNPG_VERSION}..."
kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"

kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
    -n cnpg-system --timeout=120s

# Create namespace and deploy PostgreSQL
echo ""
echo "Step 7: Deploying PostgreSQL cluster with pgvector..."
kubectl create namespace llm-d --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/postgres-cluster.yaml"

echo "Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/vectordb -n llm-d --timeout=300s

# Deploy real llm-d (not mock)
echo ""
echo "Step 8: Deploying llm-d with vLLM..."
kubectl apply -f "${SCRIPT_DIR}/llm-d-gke.yaml"

echo ""
echo "=== GKE Setup Complete ==="
echo ""
echo "Cluster: ${CLUSTER_NAME}"
echo "Zone: ${ZONE}"
echo "GPU: ${GPU_TYPE} x ${GPU_COUNT}"
echo ""
echo "Waiting for llm-d to be ready (model download may take 5-10 minutes)..."
echo "Monitor with: kubectl logs -f deployment/llm-d -n llm-d"
echo ""
echo "To test:"
echo "  kubectl port-forward svc/llm-d -n llm-d 8000:8000"
echo "  curl http://localhost:8000/v1/completions -d '{\"prompt\": \"Hello\", \"max_tokens\": 50}'"
echo ""
echo "IMPORTANT: To avoid charges, delete when done:"
echo "  ./gke-cleanup.sh"
echo ""
echo "Estimated cost: ~\$0.50-1.00/hour (T4 GPU + nodes)"
