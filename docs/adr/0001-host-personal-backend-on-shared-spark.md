---
status: accepted
---

# Host the personal backend and primary database on Spark

lyfe needs to support iPhone AI without an awake Mac, and its owner already operates a shared DGX Spark as an always-on, automatically recovering server. Host a dedicated lyfe backend and primary personal database on that Spark, separately from the shared inference service, rather than requiring the Mac to serve personal data. The owner explicitly accepts that Spark administrators could potentially access the full stored dataset, not just information selected for inference, in exchange for simpler multi-device operation and use of the existing server.

## Consequences

- Isolation from ordinary co-users, application authorization and credential separation remain requirements; administrator confidentiality is not a promised property. Database encryption alone cannot provide it when the running service can decrypt records.
- Permission to host the database is not permission to expose credentials to models, grant unrestricted tools, retain arbitrary prompt logs. Service-accessible secrets would also be exposed to host-administrator risk; their custody remains a separate design decision.
- An always-on design is not an uptime or durability guarantee. Offline client behavior, synchronization, independent backups and restoration procedures still need design and verification.
- This selects a deployment host and trust boundary, not a database engine, client framework, network product, model or key-management system. No deployment or account access is authorized by this design record.
