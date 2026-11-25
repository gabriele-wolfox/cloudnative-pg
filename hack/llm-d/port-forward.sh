#!/bin/bash
# Expose PostgreSQL and the model server(s) on localhost. Ctrl-C to stop.
set -euo pipefail

NAMESPACE=llm-d
PG_LOCAL_PORT="${PG_LOCAL_PORT:-15432}"

# `kubectl port-forward` exits whenever the remote end resets a connection,
# which PostgreSQL does on every client disconnect
# (https://github.com/kubernetes/kubernetes/issues/74551): keep restarting it.
forward() {
    while true; do
        kubectl port-forward -n "${NAMESPACE}" "$1" "$2" >/dev/null 2>&1 || true
        sleep 0.2
    done
}

cleanup() {
    trap - EXIT INT TERM
    for job in $(jobs -p); do
        children="$(pgrep -P "${job}" || true)"
        kill "${job}" 2>/dev/null || true
        if [ -n "${children}" ]; then
            # shellcheck disable=SC2086
            kill ${children} 2>/dev/null || true
        fi
    done
    exit 0
}
trap cleanup EXIT INT TERM

forward svc/vectordb-rw "${PG_LOCAL_PORT}:5432" &
forward svc/ollama 11434:11434 &
echo "PostgreSQL : localhost:${PG_LOCAL_PORT}"
echo "Ollama     : http://localhost:11434"
# vLLM (GKE / GPU setup), if deployed
if kubectl get svc/llm-d -n "${NAMESPACE}" >/dev/null 2>&1; then
    forward svc/llm-d 8000:8000 &
    echo "vLLM       : http://localhost:8000"
fi
wait
