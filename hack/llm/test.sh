#!/bin/bash
# End-to-end test: ingest the sample data and ask questions about it.
# Works against the current kubectl context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=llm
export PG_LOCAL_PORT="${PG_LOCAL_PORT:-15432}"
export RAG_TABLE="${RAG_TABLE:-rag_test}"

echo "=== Testing CloudNativePG + LLM RAG POC ==="

echo ""
echo "Test 1: PostgreSQL cluster and pgvector"
kubectl get cluster vectordb -n "${NAMESPACE}"
kubectl wait --for=condition=Ready cluster/vectordb -n "${NAMESPACE}" --timeout=60s
kubectl exec vectordb-1 -n "${NAMESPACE}" -c postgres -- \
    psql -d ragdb -tAc "SELECT 'pgvector ' || extversion FROM pg_extension WHERE extname = 'vector'"

echo ""
echo "Test 2: model server"
kubectl rollout status deployment/ollama -n "${NAMESPACE}" --timeout=60s

echo ""
echo "Starting port-forwards..."
"${SCRIPT_DIR}/port-forward.sh" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
for _ in $(seq 30); do
    (echo > "/dev/tcp/127.0.0.1/${PG_LOCAL_PORT}") 2>/dev/null \
        && (echo > /dev/tcp/127.0.0.1/11434) 2>/dev/null && break
    sleep 1
done

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"

VENV="${SCRIPT_DIR}/.venv"
if [ ! -x "${VENV}/bin/python" ]; then
    python3 -m venv "${VENV}"
    "${VENV}/bin/pip" install -q -r "${SCRIPT_DIR}/demo-app/requirements.txt"
fi
RAG=("${VENV}/bin/python" "${SCRIPT_DIR}/demo-app/rag.py")

echo ""
echo "Test 3: ingest sample data into table ${RAG_TABLE}"
"${RAG[@]}" init --reset
"${RAG[@]}" ingest-files "${SCRIPT_DIR}/demo-app/sample-data"

echo ""
echo "Test 4: ingest rows from a SQL query"
"${RAG[@]}" ingest-sql "SELECT 'faq-' || n, txt FROM (VALUES
    (1, 'The POC database is called ragdb and is owned by raguser.'),
    (2, 'The POC namespace in Kubernetes is called llm.')) AS t(n, txt)"
"${RAG[@]}" stats

echo ""
echo "Test 5: ask questions"
"${RAG[@]}" ask "Which approximate index types does pgvector support?"
"${RAG[@]}" ask "Which services does CloudNativePG create for applications?"
"${RAG[@]}" ask "What is the name of the POC database?"

echo ""
echo "=== All tests passed ==="
