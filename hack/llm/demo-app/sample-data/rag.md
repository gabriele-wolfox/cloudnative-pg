# Retrieval Augmented Generation (RAG)

Retrieval Augmented Generation grounds the answers of a large language model
in a private knowledge base. Documents are split into chunks, each chunk is
turned into a vector by an embedding model, and the vectors are stored in a
database such as PostgreSQL with pgvector.

When a question arrives, it is embedded with the same model, the closest
chunks are retrieved with a similarity search, and they are passed to the
language model as context, together with the instruction to answer only from
that context.
