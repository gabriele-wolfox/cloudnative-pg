# CloudNativePG

CloudNativePG is a Kubernetes operator that manages the full lifecycle of
PostgreSQL clusters: bootstrap, high availability with automated failover,
rolling updates, backups and point-in-time recovery, and monitoring through a
Prometheus exporter built into every instance.

A cluster is described declaratively with the `Cluster` custom resource. The
operator creates one primary and, optionally, a number of streaming replicas.
Applications connect through three services: `-rw` (primary only), `-ro`
(replicas only) and `-r` (any instance).

Extensions such as pgvector can be enabled with `CREATE EXTENSION`, either at
bootstrap time or declaratively through the `Database` resource.
