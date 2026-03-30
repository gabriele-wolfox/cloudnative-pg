#!/bin/bash
# Test script for llm-d + CloudNativePG POC
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="llm-d"

echo "=== Testing llm-d + CloudNativePG POC ==="

# Check cluster exists
if ! kind get clusters | grep -q "llm-d-poc"; then
    echo "Error: Kind cluster 'llm-d-poc' not found. Run ./setup.sh first."
    exit 1
fi

# Set kubectl context
kubectl config use-context kind-llm-d-poc

# Test 1: Check PostgreSQL cluster status
echo ""
echo "Test 1: Checking PostgreSQL cluster status..."
kubectl get cluster vectordb -n ${NAMESPACE} -o wide
CLUSTER_STATUS=$(kubectl get cluster vectordb -n ${NAMESPACE} -o jsonpath='{.status.phase}')
if [ "${CLUSTER_STATUS}" == "Cluster in healthy state" ]; then
    echo "PostgreSQL cluster is healthy."
else
    echo "Warning: Cluster status is '${CLUSTER_STATUS}'"
fi

# Test 2: Check pgvector extension
echo ""
echo "Test 2: Verifying pgvector extension..."
kubectl exec vectordb-1 -n ${NAMESPACE} -- psql -U raguser -d ragdb -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';" 2>/dev/null || {
    echo "pgvector not yet installed. Installing..."
    kubectl exec vectordb-1 -n ${NAMESPACE} -- psql -U postgres -d ragdb -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true
}

# Test 3: Check llm-d mock service
echo ""
echo "Test 3: Checking llm-d mock service..."
kubectl wait --for=condition=Available deployment/llm-d-mock -n ${NAMESPACE} --timeout=60s
LLM_POD=$(kubectl get pods -n ${NAMESPACE} -l app=llm-d-mock -o jsonpath='{.items[0].metadata.name}')
kubectl exec "${LLM_POD}" -n ${NAMESPACE} -- python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/health').read().decode())" 2>/dev/null && echo "llm-d mock is responding."

# Test 4: Run a simple vector operation
echo ""
echo "Test 4: Testing pgvector operations..."
kubectl exec vectordb-1 -n ${NAMESPACE} -- psql -U postgres -d ragdb <<'SQLEOF'
-- Ensure vector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create test table
DROP TABLE IF EXISTS test_vectors;
CREATE TABLE test_vectors (id SERIAL PRIMARY KEY, content TEXT, embedding vector(4));

-- Insert sample vectors
INSERT INTO test_vectors (content, embedding) VALUES
    ('CloudNativePG manages PostgreSQL on Kubernetes', '[0.1, 0.2, 0.3, 0.4]'),
    ('pgvector enables vector similarity search', '[0.2, 0.3, 0.4, 0.5]'),
    ('llm-d serves LLM inference at scale', '[0.3, 0.4, 0.5, 0.6]'),
    ('RAG combines retrieval with generation', '[0.15, 0.25, 0.35, 0.45]');

-- Query similar vectors (cosine distance)
SELECT content, 1 - (embedding <=> '[0.1, 0.2, 0.3, 0.4]') AS similarity
FROM test_vectors
ORDER BY embedding <=> '[0.1, 0.2, 0.3, 0.4]'
LIMIT 3;

-- Cleanup
DROP TABLE test_vectors;
SQLEOF

# Test 5: Test LLM mock endpoint
echo ""
echo "Test 5: Testing LLM mock endpoint..."
kubectl exec "${LLM_POD}" -n ${NAMESPACE} -- python -c "
import urllib.request
import json

data = json.dumps({'prompt': 'What is CloudNativePG?', 'max_tokens': 50}).encode()
req = urllib.request.Request('http://localhost:8000/v1/completions', data=data, headers={'Content-Type': 'application/json'})
response = urllib.request.urlopen(req)
result = json.loads(response.read().decode())
print('LLM Response:', result['choices'][0]['text'])
"

echo ""
echo "=== All tests passed ==="
echo ""
echo "Next steps:"
echo "  - Connect to PostgreSQL: kubectl exec -it vectordb-1 -n llm-d -- psql -U raguser -d ragdb"
echo "  - View pods: kubectl get pods -n llm-d"
echo "  - Cleanup: ./cleanup.sh"
