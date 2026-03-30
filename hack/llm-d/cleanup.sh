#!/bin/bash
# Cleanup script for llm-d + CloudNativePG POC
set -euo pipefail

echo "=== Cleaning up llm-d + CloudNativePG POC ==="

# Delete Kind cluster
if kind get clusters | grep -q "llm-d-poc"; then
    echo "Deleting Kind cluster 'llm-d-poc'..."
    kind delete cluster --name llm-d-poc
else
    echo "Kind cluster 'llm-d-poc' not found."
fi

echo "Cleanup complete."
