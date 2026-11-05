-- Module 09: ops — settings, retention, backup, installed components, updates (M1: D9, D10, D11, P8, P5)

-- ---------------------------------------------------------------------
-- 8. Settings, retention and maintenance
-- ---------------------------------------------------------------------
-- Global settings (req 67). value_json is any JSON value (scalar, array or object), so no json_type check.
CREATE TABLE setting (
    id               INTEGER PRIMARY KEY,
    key              TEXT    NOT NULL UNIQUE,          -- e.g. display.mode, auth.pin_on_control
    value_json       TEXT    NOT NULL CHECK (json_valid(value_json)),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;

-- "Delete older than" per data type; floors enforced here and in the service (requirement 51).
-- Literal floors (D1) are M11; M1 only bounds the values.
CREATE TABLE retention_policy (
    id               INTEGER PRIMARY KEY,
    data_type        TEXT    NOT NULL UNIQUE
                     CHECK (data_type IN ('event','device_state_history','audit_log','gateway_health','technical_log','export','telemetry','telemetry_rollup')),
    keep_days        INTEGER CHECK (keep_days >= 1),   -- NULL = keep forever
    min_days         INTEGER CHECK (min_days >= 0),    -- floor from the SOW
    is_archive_first INTEGER NOT NULL DEFAULT 1 CHECK (is_archive_first IN (0,1)),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK (keep_days IS NULL OR min_days IS NULL OR keep_days >= min_days),
    CHECK (data_type <> 'audit_log' OR keep_days IS NULL)   -- audit log is never deleted
) STRICT;

-- One row per retention job run (req 51). data_type uses the same domain as retention_policy.
CREATE TABLE retention_run (
    id               INTEGER PRIMARY KEY,
    data_type        TEXT    NOT NULL
                     CHECK (data_type IN ('event','device_state_history','audit_log','gateway_health','technical_log','export','telemetry','telemetry_rollup')),
    started_at       INTEGER NOT NULL CHECK (started_at > 0),
    finished_at      INTEGER CHECK (finished_at > 0),
    cutoff_time      INTEGER NOT NULL CHECK (cutoff_time > 0),
    rows_archived    INTEGER NOT NULL DEFAULT 0,
    rows_deleted     INTEGER NOT NULL DEFAULT 0,
    archive_file     TEXT,
    archive_sha256   TEXT    CHECK (length(archive_sha256) = 64 AND archive_sha256 NOT GLOB '*[^0-9a-f]*'),
    status           TEXT    NOT NULL CHECK (status IN ('running','done','skipped_no_target','failed')),
    error            TEXT
) STRICT;

-- Backups (req 97, 121). Kept while update_history references them (RESTRICT).
CREATE TABLE backup_run (
    id               INTEGER PRIMARY KEY,
    kind             TEXT    NOT NULL CHECK (kind IN ('scheduled','manual','pre_update')),
    started_at       INTEGER NOT NULL CHECK (started_at > 0),
    finished_at      INTEGER CHECK (finished_at > 0),
    target_path      TEXT    NOT NULL,
    size_bytes       INTEGER,
    sha256           TEXT    CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    is_verified      INTEGER NOT NULL DEFAULT 0 CHECK (is_verified IN (0,1)),  -- restore-tested
    status           TEXT    NOT NULL CHECK (status IN ('running','done','failed')),
    error            TEXT
) STRICT;

-- What is installed right now, one row per component (About screen, diagnostics, compatibility checks).
-- 'product' is the overall signed release (e.g. 1.2.0); the others are the parts it contains.
CREATE TABLE installed_component (
    id               INTEGER PRIMARY KEY,
    component        TEXT    NOT NULL UNIQUE
                     CHECK (component IN ('product','service','node_runtime','electron_app',
                                          'electron_runtime','ipc_protocol','os')),
    version          TEXT    NOT NULL,                 -- e.g. '1.2.0', '22.11.0', '3', '26100.2314'
    detail_json      TEXT                              -- e.g. {"chromium":"130.0","node":"20.18","support_ends":"2027-03-01"}
                     CHECK (detail_json IS NULL OR (json_valid(detail_json) AND json_type(detail_json) = 'object')),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0)
) STRICT;

-- Every update attempt, including failed and rolled-back ones (requirements 116-120)
CREATE TABLE update_history (
    id               INTEGER PRIMARY KEY,
    from_version     TEXT    NOT NULL,                 -- product version before
    to_version       TEXT    NOT NULL,                 -- product version of the package
    package_sha256   TEXT    NOT NULL                  -- signed package that was applied
                     CHECK (length(package_sha256) = 64 AND package_sha256 NOT GLOB '*[^0-9a-f]*'),
    manifest_json    TEXT                              -- component versions and minimum compatible UI/protocol/contract
                     CHECK (manifest_json IS NULL OR (json_valid(manifest_json) AND json_type(manifest_json) = 'object')),
    source           TEXT    NOT NULL CHECK (source IN ('online','offline_package')),
    started_at       INTEGER NOT NULL CHECK (started_at > 0),
    finished_at      INTEGER CHECK (finished_at > 0),
    status           TEXT    NOT NULL CHECK (status IN ('running','succeeded','failed','rolled_back')),
    failure_reason   TEXT,
    backup_run_id    INTEGER REFERENCES backup_run(id) ON DELETE RESTRICT, -- backup taken before the update
    started_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    CHECK (status = 'running' OR finished_at IS NOT NULL)
) STRICT;
CREATE INDEX ix_update_history_started_at ON update_history(started_at);
CREATE INDEX ix_update_history_backup_run_id ON update_history(backup_run_id) WHERE backup_run_id IS NOT NULL;
