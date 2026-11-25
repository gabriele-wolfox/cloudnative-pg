#!/bin/bash
# Scripted walkthrough of the POC, meant to be recorded with asciinema:
#
#   asciinema rec -c ./demo.sh demo.cast
#
# Requires ./setup.sh (or gke-setup.sh) to have completed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
export PG_LOCAL_PORT="${PG_LOCAL_PORT:-15432}"
export RAG_TABLE="${RAG_TABLE:-rag_demo}"
TYPE_DELAY="${TYPE_DELAY:-0.03}"
PAUSE="${PAUSE:-2}"

# --- silent preparation ----------------------------------------------------
./port-forward.sh >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
for _ in $(seq 30); do
    (echo > "/dev/tcp/127.0.0.1/${PG_LOCAL_PORT}") 2>/dev/null \
        && (echo > /dev/tcp/127.0.0.1/11434) 2>/dev/null && break
    sleep 1
done
# shellcheck disable=SC1091
source ./env.sh >/dev/null
if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv
    .venv/bin/pip install -q -r demo-app/requirements.txt
fi
export PATH="${SCRIPT_DIR}/.venv/bin:${SCRIPT_DIR}/demo-app:${PATH}"

# psql as raguser on ragdb: local client if installed, otherwise inside the pod
if command -v psql >/dev/null 2>&1; then
    psql() { command psql "${DATABASE_URL}" "$@"; }
else
    _pw="$(kubectl get secret vectordb-app -n llm-d -o jsonpath='{.data.password}' | base64 -d)"
    psql() {
        kubectl exec -i vectordb-1 -n llm-d -c postgres -- \
            psql "postgresql://raguser:${_pw}@localhost:5432/ragdb" "$@"
    }
fi

# --- helpers ---------------------------------------------------------------
say() {  # comment line, in cyan
    printf '\n\033[1;36m# %s\033[0m\n' "$*"
    sleep 1
}
run() {  # type the command, then run it
    printf '\033[1;32m$\033[0m '
    local cmd="$*" i
    for ((i = 0; i < ${#cmd}; i++)); do
        printf '%s' "${cmd:i:1}"
        sleep "${TYPE_DELAY}"
    done
    printf '\n'
    eval "$cmd"
    sleep "${PAUSE}"
}

# --- walkthrough -----------------------------------------------------------
clear
printf '\033[1mRAG on Kubernetes: CloudNativePG + pgvector + an LLM\033[0m\n'
sleep 2

say "PostgreSQL with pgvector, managed by CloudNativePG"
run kubectl get cluster vectordb -n llm-d
run "kubectl exec vectordb-1 -n llm-d -c postgres -- psql ragdb -tAc \"SELECT extname, extversion FROM pg_extension WHERE extname = 'vector'\""

say "Embedding + chat models, served through an OpenAI-compatible API"
run kubectl get pods -n llm-d
run "curl -s \${LLM_URL}/v1/models | python3 -m json.tool"

say "Create the vector table, sized for the embedding model"
run rag.py init --reset

say "Ingest documents from files..."
run head -5 demo-app/sample-data/pgvector.md
run rag.py ingest-files demo-app/sample-data

say "...and rows already stored in PostgreSQL"
run "psql -c \"CREATE TABLE IF NOT EXISTS faq (id int PRIMARY KEY, answer text); INSERT INTO faq VALUES (1, 'The POC database is called ragdb and is owned by raguser.'), (2, 'The POC runs in the llm-d namespace.') ON CONFLICT DO NOTHING\""
run "rag.py ingest-sql \"SELECT 'faq-' || id, answer FROM faq\""
run rag.py stats

say "The chunks are plain rows: text + vector"
run "psql -c \"SELECT source, left(regexp_replace(content, '\\s+', ' ', 'g'), 40) AS content, left(embedding::text, 40) AS embedding FROM ${RAG_TABLE} ORDER BY id\""

say "Ask a question: retrieve the closest chunks, send them to the LLM as context"
run rag.py ask --show-context -k 2 \"Which approximate index types does pgvector support?\"

say "More questions"
run rag.py ask \"Which services does CloudNativePG create for applications?\"
run rag.py ask \"What is the name of the POC database?\"

say "Out-of-scope questions are not answered from the model's own knowledge"
run rag.py ask \"Who won the 2018 football World Cup?\"

printf '\n'
sleep 2
