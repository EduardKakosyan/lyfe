---
status: accepted
---

# Swift clients with a Rust backend

The owner prefers Rust, and how much of the client would be native was open. The iPhone and Mac apps will be written in Swift and SwiftUI, sharing code where they can, while the backend on Spark stays in Rust: the API, database access, Garmin polling, streak and progression logic, model calls and the MCP server. The first-version features depend on Apple frameworks (a notification answered with typed text, a breath timer that runs with the screen locked, camera and barcode capture, offline capture, widgets), and Rust-based app toolkits reach those only through native code, so a Rust client would add a layer without removing the Swift. The owner also likes how native SwiftUI looks.

## Consequences

- Rules that must agree between phone and server, such as what counts toward a streak, live in the Rust backend; the clients display and capture, and need a defined behaviour for when they are offline.
- A shared Rust core compiled into the apps remains possible later if duplicated logic becomes a problem; it is not part of this decision.
- This was decided from general platform knowledge and earlier Apple platform research, not a fresh side-by-side evaluation of Rust client toolkits.
- This selects languages and UI framework only. Database engine, sync protocol, remote access, key custody and app distribution remain open, and implementation is not authorized by this record.
