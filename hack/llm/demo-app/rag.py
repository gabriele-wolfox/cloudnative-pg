#!/usr/bin/env python3
"""
RAG over PostgreSQL/pgvector (CloudNativePG) with an OpenAI-compatible LLM.

Sub-commands:
  init                 create the chunks table, sized for the embedding model
  ingest-files PATH... chunk, embed and store text files (.md, .txt, ...)
  ingest-sql QUERY     chunk, embed and store rows already in the database;
                       QUERY must return two columns: (source, content)
  ask QUESTION         answer a question using the stored knowledge
  chat                 interactive question/answer loop
  stats                show what has been ingested

Configuration (environment variables):
  DATABASE_URL   postgresql://raguser:...@localhost:5432/ragdb
  EMBED_URL      OpenAI-compatible base URL for embeddings (default: http://localhost:11434)
  EMBED_MODEL    embedding model name (default: nomic-embed-text)
  LLM_URL        OpenAI-compatible base URL for chat (default: http://localhost:11434)
  LLM_MODEL      chat model name (default: first model returned by LLM_URL/v1/models)
  LLM_API_KEY    optional bearer token for the LLM endpoint
  RAG_TABLE      table holding the chunks (default: rag_chunks)

Only dependency: psycopg 3 (pip install -r requirements.txt).
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import psycopg
    from psycopg import sql
except ImportError:
    sys.exit("psycopg is required: pip install -r requirements.txt")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://raguser@localhost:5432/ragdb")
EMBED_URL = os.getenv("EMBED_URL", "http://localhost:11434").rstrip("/")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
LLM_URL = os.getenv("LLM_URL", "http://localhost:11434").rstrip("/")
LLM_MODEL = os.getenv("LLM_MODEL", "")
LLM_API_KEY = os.getenv("LLM_API_KEY", "")
RAG_TABLE = os.getenv("RAG_TABLE", "rag_chunks")

CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "1200"))  # characters
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "200"))  # characters
EMBED_BATCH = int(os.getenv("EMBED_BATCH", "16"))

# nomic-embed-text is trained with task prefixes and retrieves noticeably
# better with them; other models get no prefix unless configured.
_NOMIC = EMBED_MODEL.startswith("nomic-embed")
DOC_PREFIX = os.getenv("EMBED_DOC_PREFIX", "search_document: " if _NOMIC else "")
QUERY_PREFIX = os.getenv("EMBED_QUERY_PREFIX", "search_query: " if _NOMIC else "")

SYSTEM_PROMPT = """You are an assistant that answers questions using ONLY the \
context provided by the user. The context is made of numbered excerpts.
- If the answer is not in the context, say you don't know. Do not make things up.
- Cite the excerpts you used with their number, e.g. [1] or [2][3].
- Be concise."""

TEXT_SUFFIXES = {".md", ".txt", ".rst", ".adoc", ".csv", ".json", ".yaml", ".yml", ".html", ".sql"}


# --------------------------------------------------------------------------- #
# HTTP helpers (OpenAI-compatible API)
# --------------------------------------------------------------------------- #

def _http(url, payload=None, api_key="", timeout=600):
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} from {url}: {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        sys.exit(f"Cannot reach {url}: {e.reason} (is the port-forward running?)")


def embed(texts, prefix):
    out = []
    for i in range(0, len(texts), EMBED_BATCH):
        batch = [prefix + t for t in texts[i:i + EMBED_BATCH]]
        res = _http(f"{EMBED_URL}/v1/embeddings", {"model": EMBED_MODEL, "input": batch})
        out.extend(d["embedding"] for d in sorted(res["data"], key=lambda d: d["index"]))
    return out


def llm_model():
    global LLM_MODEL
    if not LLM_MODEL:
        models = [m["id"] for m in _http(f"{LLM_URL}/v1/models", api_key=LLM_API_KEY)["data"]]
        # Ollama also lists the embedding model: skip it
        chat = [m for m in models if not m.startswith(EMBED_MODEL)]
        if not chat:
            sys.exit(f"No chat model served at {LLM_URL}; set LLM_MODEL")
        LLM_MODEL = chat[0]
    return LLM_MODEL


def chat_completion(messages, max_tokens=512):
    res = _http(f"{LLM_URL}/v1/chat/completions", {
        "model": llm_model(),
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.1,
    }, api_key=LLM_API_KEY)
    return res["choices"][0]["message"]["content"].strip()


def vec(v):
    return "[" + ",".join(f"{x:.7g}" for x in v) + "]"


# --------------------------------------------------------------------------- #
# Chunking
# --------------------------------------------------------------------------- #

def chunk_text(text, size=CHUNK_SIZE, overlap=CHUNK_OVERLAP):
    """Split on paragraph boundaries into chunks of roughly `size` characters."""
    text = re.sub(r"\n{3,}", "\n\n", text.replace("\r\n", "\n")).strip()
    if not text:
        return []
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks, current = [], ""
    for p in paragraphs:
        # Paragraphs larger than a chunk get hard-split
        while len(p) > size:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(p[:size])
            p = p[size - overlap:]
        if current and len(current) + len(p) + 2 > size:
            chunks.append(current)
            # carry over the tail of the previous chunk to preserve context
            current = current[-overlap:] + "\n\n" + p if overlap else p
        else:
            current = f"{current}\n\n{p}" if current else p
    if current:
        chunks.append(current)
    return chunks


# --------------------------------------------------------------------------- #
# Database
# --------------------------------------------------------------------------- #

def connect(attempts=20):
    # Retry briefly: port-forward.sh restarts `kubectl port-forward` after
    # every disconnection, leaving the local port closed for a moment.
    for i in range(attempts):
        try:
            return psycopg.connect(DATABASE_URL)
        except psycopg.OperationalError:
            if i == attempts - 1:
                raise
            time.sleep(0.5)


def table():
    return sql.Identifier(RAG_TABLE)


def cmd_init(args):
    dim = len(embed(["dimension probe"], DOC_PREFIX)[0])
    with connect() as conn:
        if args.reset:
            conn.execute(sql.SQL("DROP TABLE IF EXISTS {}").format(table()))
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        conn.execute(sql.SQL("""
            CREATE TABLE IF NOT EXISTS {t} (
                id          bigserial PRIMARY KEY,
                source      text NOT NULL,
                chunk_index int  NOT NULL,
                content     text NOT NULL,
                embedding   vector({dim}) NOT NULL,
                created_at  timestamptz NOT NULL DEFAULT now(),
                UNIQUE (source, chunk_index)
            )""").format(t=table(), dim=sql.Literal(dim)))
        conn.execute(sql.SQL(
            "CREATE INDEX IF NOT EXISTS {i} ON {t} USING hnsw (embedding vector_cosine_ops)"
        ).format(i=sql.Identifier(f"{RAG_TABLE}_embedding_idx"), t=table()))
    print(f"Table {RAG_TABLE} ready (model={EMBED_MODEL}, dimensions={dim}).")


def store(conn, source, text):
    """Replace all chunks of `source` with freshly embedded ones."""
    chunks = chunk_text(text)
    conn.execute(sql.SQL("DELETE FROM {} WHERE source = %s").format(table()), (source,))
    if not chunks:
        return 0
    vectors = embed(chunks, DOC_PREFIX)
    with conn.cursor() as cur:
        cur.executemany(
            sql.SQL("INSERT INTO {} (source, chunk_index, content, embedding) "
                    "VALUES (%s, %s, %s, %s::vector)").format(table()),
            [(source, i, c, vec(v)) for i, (c, v) in enumerate(zip(chunks, vectors))],
        )
    return len(chunks)


def iter_files(paths):
    for p in map(Path, paths):
        if p.is_dir():
            yield from sorted(f for f in p.rglob("*")
                              if f.is_file() and f.suffix.lower() in TEXT_SUFFIXES)
        elif p.is_file():
            yield p
        else:
            print(f"skipping {p}: not found", file=sys.stderr)


def cmd_ingest_files(args):
    total = 0
    with connect() as conn:
        for f in iter_files(args.paths):
            try:
                text = f.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                print(f"skipping {f}: not UTF-8 text", file=sys.stderr)
                continue
            n = store(conn, str(f), text)
            conn.commit()
            total += n
            print(f"{f}: {n} chunks")
    print(f"Ingested {total} chunks.")


def cmd_ingest_sql(args):
    total = 0
    with connect() as conn:
        rows = conn.execute(args.query).fetchall()
        if rows and len(rows[0]) != 2:
            sys.exit("The query must return exactly two columns: (source, content)")
        for source, content in rows:
            n = store(conn, f"{args.prefix}{source}", str(content or ""))
            conn.commit()
            total += n
        print(f"Ingested {len(rows)} rows as {total} chunks.")


def retrieve(conn, question, k):
    qv = vec(embed([question], QUERY_PREFIX)[0])
    return conn.execute(sql.SQL("""
        SELECT source, chunk_index, content, 1 - (embedding <=> %s::vector) AS similarity
        FROM {t}
        ORDER BY embedding <=> %s::vector
        LIMIT %s""").format(t=table()), (qv, qv, k)).fetchall()


def answer(conn, question, k, show_context=False):
    hits = retrieve(conn, question, k)
    if not hits:
        return "The knowledge base is empty: ingest some data first.", []
    context = "\n\n".join(f"[{i}] (source: {s}#{c})\n{txt}"
                          for i, (s, c, txt, _) in enumerate(hits, 1))
    if show_context:
        print("----- context -----\n" + context + "\n-------------------")
    reply = chat_completion([
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"},
    ])
    return reply, hits


def print_answer(reply, hits):
    print(f"\n{reply}\n\nSources:")
    for i, (s, c, _, sim) in enumerate(hits, 1):
        print(f"  [{i}] {s}#{c}  (similarity {sim:.3f})")


def cmd_ask(args):
    with connect() as conn:
        print_answer(*answer(conn, " ".join(args.question), args.k, args.show_context))


def cmd_chat(args):
    print(f"Chatting with {llm_model()} over {RAG_TABLE}. Empty line or Ctrl-D to quit.")
    with connect() as conn:
        while True:
            try:
                q = input("\n> ").strip()
            except EOFError:
                break
            if not q:
                break
            print_answer(*answer(conn, q, args.k, args.show_context))


def cmd_stats(_args):
    with connect() as conn:
        rows = conn.execute(sql.SQL(
            "SELECT source, count(*) FROM {} GROUP BY source ORDER BY source").format(table())
        ).fetchall()
    for source, n in rows:
        print(f"{n:6d}  {source}")
    print(f"{sum(n for _, n in rows):6d}  chunks in {len(rows)} sources")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init", help="create the chunks table")
    p.add_argument("--reset", action="store_true", help="drop the table first")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("ingest-files", help="ingest text files or directories")
    p.add_argument("paths", nargs="+")
    p.set_defaults(func=cmd_ingest_files)

    p = sub.add_parser("ingest-sql", help="ingest rows returned by a query: (source, content)")
    p.add_argument("query")
    p.add_argument("--prefix", default="sql:", help="prefix for the source name (default: sql:)")
    p.set_defaults(func=cmd_ingest_sql)

    for name, func in (("ask", cmd_ask), ("chat", cmd_chat)):
        p = sub.add_parser(name)
        if name == "ask":
            p.add_argument("question", nargs="+")
        p.add_argument("-k", type=int, default=5, help="number of chunks to retrieve")
        p.add_argument("--show-context", action="store_true",
                       help="print the retrieved context sent to the LLM")
        p.set_defaults(func=func)

    sub.add_parser("stats", help="show ingested sources").set_defaults(func=cmd_stats)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
