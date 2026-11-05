-- Module 00: header — file-creation pragmas and the migration log (M1: P2, P3, N5)

-- =====================================================================
-- Omniconn Fire Alarm Workstation — SQLite schema v3 (in development; Draft v2 is the frozen baseline)
-- Owner: the monitoring service is the single writer. Desktop and web clients never open this file;
-- they reach the data through the service over authenticated IPC (req 81).
--
-- Conventions: see CLAUDE.md (enforced by npm run db:lint) and docs/db/DECISIONS.md.
--   * Times are INTEGER UTC milliseconds since the Unix epoch, CHECK (> 0). src_time = source/controller
--     time, rcv_time = time the service received it. Local time is never stored.
--   * Connection settings (WAL, synchronous=FULL, foreign_keys, trusted_schema OFF, DEFENSIVE, checkpoint
--     ownership) are applied and asserted on every open by db/tools/connection.js; see
--     docs/db/CONNECTION_PROFILE.md (req 97, P1).
--
-- File-creation pragmas. The build runs these lines on the empty file before the first CREATE TABLE,
-- because page_size and auto_vacuum cannot be changed afterwards without a full VACUUM (P2).
-- user_version is the schema version of record (N5). The build sets it last, inside the build
-- transaction, only after foreign_key_check passes, so a failed build leaves it at 0.
-- =====================================================================
PRAGMA page_size = 4096;
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA application_id = 1330466377;
PRAGMA user_version = 3;
-- page_size 4096 matches the NTFS cluster size on the MS-01. auto_vacuum=INCREMENTAL lets the
-- service return pages freed by retention deletes with PRAGMA incremental_vacuum (req 51).
-- application_id 1330466377 = 0x4F4D4E49 ('OMNI'), identifies an Omniconn workstation database (P3).

-- ---------------------------------------------------------------------
-- 0. Migration log (N5). One row per schema module applied at a version. PRAGMA user_version is the
--    truth for "which schema is this file"; this table records how it got there and proves the module
--    text applied (checksum). Append-only.
-- ---------------------------------------------------------------------
CREATE TABLE schema_version (
    id           INTEGER PRIMARY KEY,
    version      INTEGER NOT NULL CHECK (version >= 1),       -- equals PRAGMA user_version after the run
    module       TEXT    NOT NULL,                            -- e.g. '03_events_alarms' or a migration name
    checksum     TEXT    NOT NULL                             -- sha256 (hex) of the module text as applied
                 CHECK (length(checksum) = 64 AND checksum NOT GLOB '*[^0-9a-f]*'),
    applied_at   INTEGER NOT NULL CHECK (applied_at > 0),
    applied_by   TEXT    NOT NULL,                            -- process identity, e.g. 'db:build', 'service 1.2.0'
    description  TEXT    NOT NULL,
    UNIQUE (version, module)
) STRICT;

CREATE TRIGGER trg_schema_version_no_update BEFORE UPDATE ON schema_version
BEGIN SELECT RAISE(ABORT, 'schema_version: append-only'); END;
CREATE TRIGGER trg_schema_version_no_delete BEFORE DELETE ON schema_version
BEGIN SELECT RAISE(ABORT, 'schema_version: append-only'); END;
