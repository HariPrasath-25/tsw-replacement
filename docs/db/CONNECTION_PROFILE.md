# Connection profile — workstation database

Requirement 97 (durable local store, no committed event lost on power cut), P1, ADR-003. The reference implementation is `db/tools/connection.js`, and `db/tests/connection.test.js` asserts every value below. The monitoring service must apply this profile on **every** connection it opens, then assert it, and refuse to start (raising a Trouble condition) if the assertion fails.

## 1. Roles

| Role | Count | Opened by | Purpose |
|---|---|---|---|
| **writer** | exactly 1 | the service's DB writer thread | all INSERT/UPDATE/DELETE, checkpoints, retention, migrations |
| **reader** | 0..n | service query workers (reports, statistics, exports, UI queries over IPC) | read-only, never takes a write lock (req 99) |

The desktop and web clients never open the file (CLAUDE.md, req 81).

## 2. Settings

All values are applied with `PRAGMA` after open and **read back** by `assertProfile`.

| Setting | Writer | Reader | Why |
|---|---|---|---|
| `journal_mode` | `WAL` | `wal` (asserted; persistent in the file) | Readers don't block the writer, and the writer doesn't block readers. The alarm path never waits on a report (T1, req 99). |
| `synchronous` | `FULL` (2) | `FULL` | In WAL mode, FULL fsyncs the WAL on every COMMIT, so a returned COMMIT is durable across power loss (req 97). `NORMAL` can lose the last transactions. |
| `foreign_keys` | `ON` | `ON` | Off by default in SQLite, per connection. Every RESTRICT in ADR-001 depends on it. |
| `trusted_schema` | `OFF` | `OFF` | SQL functions and virtual tables referenced from the schema (triggers, views, CHECKs) can't run with application privilege. Guards against a tampered file. |
| DEFENSIVE (`SQLITE_DBCONFIG_DEFENSIVE`) | on | on | Blocks writing `sqlite_schema`, `PRAGMA writable_schema` corruption and similar. better-sqlite3 enables it on open, and the service must never call `db.unsafeMode()`. There is no PRAGMA to read it back, so it's asserted by behaviour: with `writable_schema=ON`, preparing an UPDATE on `sqlite_schema` must fail. |
| `busy_timeout` | `5000` ms | `5000` ms | Readers can briefly wait on WAL index recovery. With a single writer, a timeout points to a bug, never to normal contention. |
| `wal_autocheckpoint` | `0` | `0` | The service owns checkpointing (§4). It never runs inside an ingest commit. |
| `journal_size_limit` | `67108864` (64 MiB) | same | After a TRUNCATE/RESTART checkpoint, the WAL file is cut back so disk use stays bounded. |
| `temp_store` | `MEMORY` | `MEMORY` | Sorts and temp b-trees never touch disk. |
| `cache_size` | `-65536` (64 MiB) | `-32768` (32 MiB) | Hot pages of `event`/`alarm`/`device_state` and their indexes. See §6. |
| `mmap_size` | `0` | `0` | An I/O error on a memory-mapped page crashes the process instead of returning `SQLITE_IOERR`. For a life-safety service, an error the code can handle is better than a crash. |
| `query_only` | `OFF` | `ON` | A reader can't write, even through a bug. |
| `application_id` | `1330466377` (0x4F4D4E49 'OMNI') | same | Refuses to open a file that isn't an Omniconn workstation database (P3). |
| `user_version` | `3` | same | Refuses a schema version the binary wasn't built for. Migrations are applied by the writer before readers open (ADR-004). |
| SQLite version | ≥ 3.45 | ≥ 3.45 | STRICT, JSONB, `RETURNING`, UPSERT. |

File-creation settings (`page_size=4096`, `auto_vacuum=INCREMENTAL`, `application_id`) are in `db/schema/00_header.sql`. They are applied before the first CREATE TABLE and can't be changed on a live file (P2).

## 3. Transactions and the commit-before-ack rule (req 97)

1. Every write transaction starts with **`BEGIN IMMEDIATE`**, which takes the write lock up front. A deferred BEGIN that upgrades later can fail with `SQLITE_BUSY` halfway through.
2. Ingest is idempotent: `INSERT … ON CONFLICT DO NOTHING RETURNING id`. A replayed message (`UNIQUE (gateway_hardware_id, source_event_id)`) returns no row and is still acknowledged.
3. **An event is acknowledged to the source (MQTT PUBACK or the gateway's ack), pushed to clients or shown as recorded only after `COMMIT` has returned successfully.** With `synchronous=FULL`, a returned COMMIT means the WAL frame is on disk. If COMMIT throws, roll back, don't ack, and let the source redeliver.
4. Batch ingest: several messages can share one transaction to amortise the fsync. Each message in the batch is acked only after that batch's COMMIT returns.
5. Commands (req 9–12) are written as `pending` and committed **before** dispatch to the gateway, so a crash can never produce an undocumented or repeated command.

`connection.writeTx(db, fn)` shows the pattern: it returns only after COMMIT, and rolls back on any error.

## 4. Checkpoint ownership (writer only)

Because `wal_autocheckpoint=0`, nothing checkpoints unless the service does. The writer thread runs this policy. All numbers are proposed defaults, to revisit with the M12 benchmarks.

| Trigger | Action | Notes |
|---|---|---|
| Every **30 s**, or when the WAL reaches **1,000 frames** (~4 MB), whichever comes first | `PRAGMA wal_checkpoint(PASSIVE)` | Never blocks readers or the writer. It may checkpoint only part of the WAL if readers hold old snapshots. |
| Writer idle for **60 s** (no ingest) **and** no reader transaction open | `PRAGMA wal_checkpoint(TRUNCATE)` | Resets the WAL to zero bytes. Readers aren't blocked for long, because none are open. |
| WAL file ≥ **64 MiB** | Raise a **warning** in the technical log and service health | It usually means a long-running reader is pinning the WAL. Find and end it. |
| WAL file ≥ **256 MiB** | Raise a **Trouble** condition (service-generated alarm, req 22/24 pattern, G1 in M5) | Recovery time and disk use are now at risk. Readers are told to finish, then the writer runs TRUNCATE. |
| After a retention run | `PRAGMA incremental_vacuum(N)` in bounded steps, then PASSIVE | Hands freed pages back to the file system (P2, req 51). |

Only the writer checkpoints. Reader connections never run `wal_checkpoint`.

## 5. Maintenance (writer, off the alarm path)

- `PRAGMA optimize` on connection close and every few hours (P7).
- `PRAGMA quick_check` daily and `PRAGMA foreign_key_check` weekly. Results go in the technical log, and a failure raises Trouble.
- Backups use the online backup API or `VACUUM INTO` from a reader snapshot, never a file copy of a live WAL database (req 97, 121). M11 covers the details.

## 6. Cache and mmap sizing guidance

- **Writer cache (64 MiB):** sized to hold the right-hand edge of the `event` b-tree, its two indexes, `alarm`, `device_state` and the reference tables. At 50 events/s, this keeps ingest at roughly zero read I/O. Revisit with the M12 ingest benchmark (T7).
- **Reader cache (32 MiB per connection):** keep the pool small (2–4 readers). Each connection's cache is private, so total memory is `writer + n × reader`. On the MS-01, also budget for the desktop app, gateway workloads and backup (architecture §5).
- **mmap stays at 0.** Revisit only if M12 shows a read-latency gain that matters, and only together with a crash-safety review.
- **page_size 4096** matches the NTFS cluster and the sector-atomic write size. Don't change it without a rebuild-and-migrate plan.

## 7. PostgreSQL portability

`synchronous_commit=on`, `fsync=on` and `full_page_writes=on` give the same commit-before-ack guarantee. Checkpointing (`checkpoint_timeout`, `max_wal_size`) belongs to the server. Read-only roles or `default_transaction_read_only` replace `query_only`. There is no DEFENSIVE equivalent; role privileges cover it. See ADR-003.
