-- Module 04: telemetry (split verbatim from Draft v2 in M0; source of truth from here on)

-- ---------------------------------------------------------------------
-- 3b. Telemetry: rules first, then data
--     The service reads telemetry_key (+ per-type overrides) to decide, for each
--     incoming value, whether to store it, how, and how to roll it up.
-- ---------------------------------------------------------------------
CREATE TABLE telemetry_key (
    id                INTEGER PRIMARY KEY,
    code              TEXT    NOT NULL UNIQUE,         -- our name, e.g. 'sensitivity', 'cpu_pct'
    name              TEXT    NOT NULL,
    unit              TEXT,                            -- '%/ft', '%', 'degC', 'count'
    value_kind        TEXT    NOT NULL CHECK (value_kind IN ('numeric','boolean','enum','counter')),
                       -- counter = always-increasing total; roll-ups store the increase (delta)
    storage_mode      TEXT    NOT NULL CHECK (storage_mode IN ('on_change','deadband','interval','latest_only','ignore')),
                       -- on_change: store when value differs; deadband: store when |change| >= deadband;
                       -- interval: store at most every interval_sec; latest_only: update latest value only
    deadband          REAL,                            -- used by 'deadband'
    interval_sec      INTEGER,                         -- used by 'interval'; also max gap for 'deadband'
    rollup            TEXT    NOT NULL DEFAULT 'none' CHECK (rollup IN ('none','hourly','daily','hourly_daily')),
    decimals          INTEGER NOT NULL DEFAULT 2,
    raw_keep_days     INTEGER,                         -- days to keep raw rows; NULL = retention_policy 'telemetry' default
    rollup_keep_days  INTEGER,                         -- days to keep roll-ups;  NULL = retention_policy 'telemetry_rollup' default
                       -- Effective retention (see v_telemetry_retention): the key's own value if set, otherwise
                       -- the policy default; never below the policy's min_days. Keys may be longer OR shorter
                       -- than the default (e.g. sensitivity has no roll-up, so it keeps raw history for 3 years).
    CHECK (storage_mode <> 'deadband' OR deadband IS NOT NULL),
    CHECK (storage_mode <> 'interval' OR interval_sec IS NOT NULL)
) STRICT;

-- Which keys apply to which device type, with optional overrides and maintenance thresholds.
-- Thresholds raise advisories (e.g. 'detector dirty'), never fire alarms: alarms come from the controller.
CREATE TABLE device_type_telemetry (
    id                INTEGER PRIMARY KEY,
    device_type_id    INTEGER NOT NULL REFERENCES device_type(id),
    telemetry_key_id  INTEGER NOT NULL REFERENCES telemetry_key(id),
    storage_mode      TEXT    CHECK (storage_mode IN ('on_change','deadband','interval','latest_only','ignore')),
    deadband          REAL,
    interval_sec      INTEGER,
    advisory_low      REAL,
    advisory_high     REAL,                            -- e.g. average_value above this = cleaning due
    UNIQUE (device_type_id, telemetry_key_id)
) STRICT;

-- Vendor/gateway field names -> our keys, with optional scaling (value * scale + value_offset)
CREATE TABLE vendor_key_map (
    id                INTEGER PRIMARY KEY,
    vendor            TEXT    NOT NULL,                -- 'Simplex', 'Omniconn Gateway'
    raw_key           TEXT    NOT NULL,                -- e.g. 'presentSensitivitySelected'
    telemetry_key_id  INTEGER NOT NULL REFERENCES telemetry_key(id),
    scale             REAL    NOT NULL DEFAULT 1,
    value_offset      REAL    NOT NULL DEFAULT 0,
    enum_map_json     TEXT,                            -- for enum keys: {"NORMAL":0,"DIRTY":1,...}
    UNIQUE (vendor, raw_key)
) STRICT;

-- Raw readings that passed the storage rule. Numbers only (booleans 0/1, enums as codes).
-- Exception to the "id primary key" convention: high-volume, never referenced by other tables,
-- always read by device + key + time. A composite key stored WITHOUT ROWID keeps each reading
-- once, in that order (about half the size and faster trend queries than id + UNIQUE index).
CREATE TABLE telemetry (
    device_id         INTEGER NOT NULL REFERENCES device(id),
    telemetry_key_id  INTEGER NOT NULL REFERENCES telemetry_key(id),
    ts                INTEGER NOT NULL,                -- source time if trusted, else receive time (UTC ms)
    value             REAL    NOT NULL,
    PRIMARY KEY (device_id, telemetry_key_id, ts)
) STRICT, WITHOUT ROWID;

-- Gateway-level readings (CPU, memory, buffer depth) use the same rules; same exception as above
CREATE TABLE gateway_telemetry (
    gateway_id        INTEGER NOT NULL REFERENCES gateway(id),
    telemetry_key_id  INTEGER NOT NULL REFERENCES telemetry_key(id),
    ts                INTEGER NOT NULL,
    value             REAL    NOT NULL,
    PRIMARY KEY (gateway_id, telemetry_key_id, ts)
) STRICT, WITHOUT ROWID;

-- Roll-ups for long-term trends and reports (devices and gateways)
CREATE TABLE telemetry_rollup (
    id                INTEGER PRIMARY KEY,
    source_kind       TEXT    NOT NULL CHECK (source_kind IN ('device','gateway')),
    source_id         INTEGER NOT NULL,                -- device.id or gateway.id
    telemetry_key_id  INTEGER NOT NULL REFERENCES telemetry_key(id),
    period            TEXT    NOT NULL CHECK (period IN ('hour','day')),
    period_ts         INTEGER NOT NULL,                -- start of the hour/day, UTC ms
    min_value         REAL,
    max_value         REAL,
    avg_value         REAL,
    last_value        REAL,
    delta_value       REAL,                            -- counters: increase within the period
    samples           INTEGER NOT NULL,
    UNIQUE (source_kind, source_id, telemetry_key_id, period, period_ts)
) STRICT;
