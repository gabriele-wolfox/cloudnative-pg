# pgvector

pgvector is a PostgreSQL extension for vector similarity search. It adds the
`vector` data type and distance operators: `<->` (Euclidean), `<#>` (negative
inner product) and `<=>` (cosine distance).

It supports exact nearest-neighbour search and two approximate index types:
IVFFlat, which partitions vectors into lists, and HNSW, which builds a
multi-layer graph and offers a better speed/recall trade-off at the cost of
slower index builds and more memory.
