#!/bin/bash
# GKE Cleanup script - IMPORTANT: Run this to avoid charges!
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${GCP_ZONE:-us-central1-a}"
CLUSTER_NAME="${CLUSTER_NAME:-llm-d-poc}"

echo "=== GKE Cleanup ==="
echo ""
echo "This will DELETE the following resources:"
echo "  - GKE cluster: ${CLUSTER_NAME}"
echo "  - All workloads and data in the cluster"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "${confirm}" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Deleting GKE cluster '${CLUSTER_NAME}'..."
gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --quiet

echo ""
echo "Cleanup complete. Verify no resources remain:"
echo "  gcloud container clusters list --project=${PROJECT_ID}"
echo "  https://console.cloud.google.com/billing"
