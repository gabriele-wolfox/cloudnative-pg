#!/usr/bin/env python3
"""
RAG Demo: PostgreSQL/pgvector + llm-d integration
Demonstrates storing embeddings and querying with context augmentation.
"""

import os
import json
import urllib.request
import urllib.error

# Configuration from environment
PG_HOST = os.getenv("PG_HOST", "localhost")
PG_PORT = os.getenv("PG_PORT", "5432")
PG_DATABASE = os.getenv("PG_DATABASE", "ragdb")
PG_USER = os.getenv("PG_USER", "raguser")
PG_PASSWORD = os.getenv("PG_PASSWORD", "ragpassword")
LLM_URL = os.getenv("LLM_URL", "http://localhost:8000")

# Sample documents for the demo
SAMPLE_DOCS = [
    {
        "title": "CloudNativePG Overview",
        "content": "CloudNativePG is a Kubernetes operator for PostgreSQL that manages the full lifecycle of PostgreSQL clusters. It supports high availability, backups, and monitoring.",
        # Mock embedding (in production, use actual embedding model)
        "embedding": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8] * 16  # 128-dim
    },
    {
        "title": "pgvector Extension",
        "content": "pgvector is a PostgreSQL extension for vector similarity search. It supports exact and approximate nearest neighbor search using IVFFlat and HNSW indexes.",
        "embedding": [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9] * 16
    },
    {
        "title": "llm-d Architecture",
        "content": "llm-d is a high-performance distributed inference serving stack for LLMs on Kubernetes. It uses vLLM for model serving and provides intelligent load balancing.",
        "embedding": [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0] * 16
    },
    {
        "title": "RAG Pattern",
        "content": "Retrieval Augmented Generation (RAG) combines vector search with LLM generation. Documents are embedded and stored, then retrieved based on query similarity to augment LLM prompts.",
        "embedding": [0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85] * 16
    },
]


def get_connection():
    """Get PostgreSQL connection using psycopg."""
    try:
        import psycopg
        return psycopg.connect(
            host=PG_HOST,
            port=PG_PORT,
            dbname=PG_DATABASE,
            user=PG_USER,
            password=PG_PASSWORD,
        )
    except ImportError:
        print("psycopg not installed. Install with: pip install psycopg[binary]")
        raise


def setup_schema(conn):
    """Create the documents table with vector support."""
    with conn.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute("""
            CREATE TABLE IF NOT EXISTS documents (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                embedding vector(128)
            );
        """)
        # Create HNSW index for fast similarity search
        cur.execute("""
            CREATE INDEX IF NOT EXISTS documents_embedding_idx
            ON documents USING hnsw (embedding vector_cosine_ops);
        """)
        conn.commit()
    print("Schema created successfully.")


def load_documents(conn):
    """Load sample documents into the database."""
    with conn.cursor() as cur:
        # Clear existing documents
        cur.execute("TRUNCATE documents RESTART IDENTITY;")

        for doc in SAMPLE_DOCS:
            cur.execute(
                "INSERT INTO documents (title, content, embedding) VALUES (%s, %s, %s)",
                (doc["title"], doc["content"], doc["embedding"])
            )
        conn.commit()
    print(f"Loaded {len(SAMPLE_DOCS)} documents.")


def search_similar(conn, query_embedding, limit=3):
    """Find documents similar to the query embedding."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT title, content, 1 - (embedding <=> %s::vector) as similarity
            FROM documents
            ORDER BY embedding <=> %s::vector
            LIMIT %s;
        """, (query_embedding, query_embedding, limit))
        return cur.fetchall()


def query_llm(prompt: str, context: str) -> str:
    """Send a query to the LLM with retrieved context."""
    full_prompt = f"""Context information:
{context}

Based on the above context, please answer the following question:
{prompt}
"""

    request_data = json.dumps({
        "prompt": full_prompt,
        "max_tokens": 200,
    }).encode('utf-8')

    req = urllib.request.Request(
        f"{LLM_URL}/v1/completions",
        data=request_data,
        headers={"Content-Type": "application/json"},
        method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.loads(response.read().decode('utf-8'))
            return result.get("choices", [{}])[0].get("text", "No response")
    except urllib.error.URLError as e:
        return f"LLM query failed: {e}"


def demo_rag_query(conn, question: str):
    """Demonstrate a complete RAG query flow."""
    print(f"\n{'='*60}")
    print(f"Question: {question}")
    print('='*60)

    # Mock query embedding (in production, embed the question)
    query_embedding = [0.18, 0.28, 0.38, 0.48, 0.58, 0.68, 0.78, 0.88] * 16

    # Step 1: Retrieve similar documents
    print("\n1. Retrieving relevant documents from pgvector...")
    results = search_similar(conn, query_embedding, limit=2)

    context_parts = []
    for title, content, similarity in results:
        print(f"   - {title} (similarity: {similarity:.3f})")
        context_parts.append(f"- {title}: {content}")

    context = "\n".join(context_parts)

    # Step 2: Query LLM with context
    print("\n2. Querying LLM with augmented context...")
    response = query_llm(question, context)

    print(f"\n3. LLM Response:\n{response}")
    return response


def main():
    print("RAG Demo: CloudNativePG + pgvector + llm-d")
    print("=" * 50)

    conn = get_connection()

    # Setup
    print("\nSetting up database schema...")
    setup_schema(conn)

    print("\nLoading sample documents...")
    load_documents(conn)

    # Demo queries
    demo_rag_query(conn, "What is CloudNativePG and how does it help with PostgreSQL?")
    demo_rag_query(conn, "How does RAG work with vector databases?")

    conn.close()
    print("\n" + "=" * 50)
    print("Demo completed!")


if __name__ == "__main__":
    main()
