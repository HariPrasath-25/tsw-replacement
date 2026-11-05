-- Module 09: ops (split verbatim from Draft v2 in M0; source of truth from here on)

-- ---------------------------------------------------------------------
-- 8. Settings, retention and maintenance
-- ---------------------------------------------------------------------
CREATE TABLE setting (
    id               INTEGER PRIMARY KEY,
    key              TEXT    NOT NULL UNIQUE,          -- e.g. display.mode, auth.pin_on_control
    value_json       TEXT    NOT NULL,
    updated_by       INTEGER REFERENCES user_account(id),
    updated_at       INTEGER NOT NULL
) STRICT;

-- "Delete older than" per data type; floors enforced here and in the service (requirement 51)
CREATE TABLE retention_policy (
    id               INTEGER PRIMARY KEY,
    data_type        TEXT    NOT NULL UNIQUE
                     CHECK (data_type IN ('event','device_state_history','audit_log','gateway_health','technical_log','export','telemetry','telemetry_rollup')),
    keep_days        INTEGER,                          -- NULL = keep forever
    min_days         INTEGER,                          -- floor from the SOW
    archive_first    INTEGER NOT NULL DEFAULT 1 CHECK (archive_first IN (0,1)),
    updated_by       INTEGER REFERENCES user_account(id),
    updated_at       INTEGER NOT NULL,
    CHECK (keep_days IS NULL OR min_days IS NULL OR keep_days >= min_days),
    CHECK (data_type <> 'audit_log' OR keep_days IS NULL)   -- audit log is never deleted
) STRICT;

CREATE TABLE retention_run (
    id               INTEGER PRIMARY KEY,
    data_type        TEXT    NOT NULL,
    started_at       INTEGER NOT NULL,
    finished_at      INTEGER,
    cutoff_time      INTEGER NOT NULL,
    rows_archived    INTEGER NOT NULL DEFAULT 0,
    rows_deleted     INTEGER NOT NULL DEFAULT 0,
    archive_file     TEXT,
    archive_sha256   TEXT,
    status           TEXT    NOT NULL CHECK (status IN ('running','done','skipped_no_target','failed')),
    error            TEXT
) STRICT;

CREATE TABLE backup_run (
    id               INTEGER PRIMARY KEY,
    kind             TEXT    NOT NULL CHECK (kind IN ('scheduled','manual','pre_update')),
    started_at       INTEGER NOT NULL,
    finished_at      INTEGER,
    target_path      TEXT    NOT NULL,
    size_bytes       INTEGER,
    sha256           TEXT,
    verified         INTEGER NOT NULL DEFAULT 0 CHECK (verified IN (0,1)),  -- restore-tested
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
    detail_json      TEXT,                             -- e.g. {"chromium":"130.0","node":"20.18","support_ends":"2027-03-01"}
    updated_at       INTEGER NOT NULL
) STRICT;

-- Every update attempt, including failed and rolled-back ones (requirements 116-120)
CREATE TABLE update_history (
    id               INTEGER PRIMARY KEY,
    from_version     TEXT    NOT NULL,                 -- product version before
    to_version       TEXT    NOT NULL,                 -- product version of the package
    package_sha256   TEXT    NOT NULL,                 -- signed package that was applied
    manifest_json    TEXT,                             -- component versions and minimum compatible UI/protocol/contract
    source           TEXT    NOT NULL CHECK (source IN ('online','offline_package')),
    started_at       INTEGER NOT NULL,
    finished_at      INTEGER,
    status           TEXT    NOT NULL CHECK (status IN ('running','succeeded','failed','rolled_back')),
    failure_reason   TEXT,
    backup_run_id    INTEGER REFERENCES backup_run(id), -- backup taken before the update
    started_by       INTEGER REFERENCES user_account(id),
    CHECK (status = 'running' OR finished_at IS NOT NULL)
) STRICT;
CREATE INDEX ix_update_started ON update_history(started_at);
