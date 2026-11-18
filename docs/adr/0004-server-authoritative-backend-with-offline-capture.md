---
status: accepted
---

# Server-authoritative backend with offline capture

lyfe has to work on an iPhone that is often away from home and sometimes without connectivity, against a backend on a shared machine. The apps reach the Rust backend over Tailscale only, with lyfe's own sign-in on top; the backend keeps its data in a dedicated PostgreSQL database under its own account, separate from the shared model service. The phone stores each capture locally and sends it when the backend is reachable, with a unique identifier per capture so a retry cannot count twice. The backend alone decides streaks, progression and targets, and an offline phone shows the last synced state together with its age. An encrypted backup leaves Spark on a schedule.

Full two-way synchronisation between equal replicas was not chosen: with one user, capture-then-upload is enough, and keeping one authority avoids the phone and server disagreeing about whether a streak is alive. PostgreSQL was chosen over a single-file database because several backend jobs write concurrently and note search benefits from it; for one user either would work.

## Consequences

- With Tailscale off or Spark unreachable, the phone can still capture but cannot show fresh streak state, new tables or model output; the offline experience has to be designed around that.
- Nothing may require Spark to accept connections from the public internet in the first version. A bank-data provider that needs to call in would reopen this.
- Tailnet access rules for other Spark users, key custody, the backup destination and restore testing remain open.
- This does not authorize deploying anything to Spark.
