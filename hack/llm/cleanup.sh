#!/bin/bash
# Cleanup script for the local (Kind) POC
set -euo pipefail

echo "=== Cleaning up CloudNativePG + LLM RAG POC ==="

if kind get clusters | grep -qx "llm-poc"; then
    echo "Deleting Kind cluster 'llm-poc'..."
    kind delete cluster --name llm-poc
else
    echo "Kind cluster 'llm-poc' not found."
fi
rm -rf "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.venv"

echo "Cleanup complete."
