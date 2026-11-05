-- Module 00: header (split verbatim from Draft v2 in M0; source of truth from here on)

-- =====================================================================
-- Omniconn Fire Alarm Workstation - SQLite schema (v1, draft)
-- Owner: monitoring service (single writer). The Electron UI never opens this file.
--
-- Conventions
--   * Every table has a single primary key column named id (INTEGER), except the two raw
--     telemetry tables (telemetry, gateway_telemetry), which use a composite key for size and speed.
--     Natural keys (codes, serials, composite links) are UNIQUE constraints.
--     Foreign keys are named <table>_id and reference <table>(id).
--   * Times are INTEGER milliseconds since Unix epoch, UTC (src_time = controller/source time,
--     rcv_time = time the service received it). Displayed in local time with zone.
--   * Flexible vendor data is TEXT holding JSON.
--   * STRICT tables need SQLite 3.37+ (bundled with better-sqlite3).
--   * Connection pragmas (set by the service on open, not stored here):
--       PRAGMA journal_mode = WAL;  PRAGMA synchronous = FULL;  PRAGMA foreign_keys = ON;
--       PRAGMA busy_timeout = 5000; PRAGMA trusted_schema = OFF; PRAGMA wal_autocheckpoint = 0;
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Schema version (migrations)
-- ---------------------------------------------------------------------
CREATE TABLE schema_version (
    id           INTEGER PRIMARY KEY,
    version      INTEGER NOT NULL UNIQUE,
    applied_at   INTEGER NOT NULL,
    description  TEXT    NOT NULL
) STRICT;
