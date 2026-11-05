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

-- ---------------------------------------------------------------------
-- 1. Tenancy, sites and spaces
-- ---------------------------------------------------------------------
CREATE TABLE tenant (
    id           INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL UNIQUE,
    status       TEXT    NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','archived')),
    created_at   INTEGER NOT NULL
) STRICT;

CREATE TABLE site (
    id           INTEGER PRIMARY KEY,
    tenant_id    INTEGER NOT NULL REFERENCES tenant(id),
    name         TEXT    NOT NULL,
    timezone     TEXT    NOT NULL DEFAULT 'Asia/Dubai',
    created_at   INTEGER NOT NULL,
    UNIQUE (tenant_id, name)
) STRICT;

-- Building > floor > zone (at least three levels, requirement 30)
CREATE TABLE space (
    id           INTEGER PRIMARY KEY,
    site_id      INTEGER NOT NULL REFERENCES site(id),
    parent_id    INTEGER REFERENCES space(id),
    type         TEXT    NOT NULL CHECK (type IN ('building','floor','zone','room','other')),
    name         TEXT    NOT NULL,
    sort_order   INTEGER NOT NULL DEFAULT 0
) STRICT;
CREATE INDEX ix_space_site_parent ON space(site_id, parent_id);

-- width_px / height_px / size_bytes / sha256 are read from the file by the service on upload
CREATE TABLE floor_plan (
    id           INTEGER PRIMARY KEY,
    space_id     INTEGER NOT NULL REFERENCES space(id),
    file_name    TEXT    NOT NULL,
    mime_type    TEXT    NOT NULL CHECK (mime_type IN ('image/png','image/jpeg','image/webp','image/svg+xml')),
    width_px     INTEGER NOT NULL CHECK (width_px  BETWEEN 1 AND 8192),
    height_px    INTEGER NOT NULL CHECK (height_px BETWEEN 1 AND 8192),
    size_bytes   INTEGER NOT NULL CHECK (size_bytes <= 20971520),   -- 20 MB
    sha256       TEXT    NOT NULL,
    storage_path TEXT    NOT NULL,          -- file kept on disk, not in the database
    is_current   INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0,1)),
    uploaded_by  INTEGER REFERENCES user_account(id),
    uploaded_at  INTEGER NOT NULL
) STRICT;

-- ---------------------------------------------------------------------
-- 2. Sources: gateways, controllers, devices
-- ---------------------------------------------------------------------
-- Logical gateway: its id never changes, so events, controllers and history stay attached
-- when the physical box is swapped. The physical unit (serial) lives in gateway_hardware.
CREATE TABLE gateway (
    id               INTEGER PRIMARY KEY,
    site_id          INTEGER NOT NULL REFERENCES site(id),
    space_id         INTEGER REFERENCES space(id),     -- where the gateway is installed, e.g. GF FCC room
    name             TEXT    NOT NULL,
    runtime_version  TEXT,
    contract_version TEXT,
    last_heartbeat   INTEGER,
    conn_state       TEXT    NOT NULL DEFAULT 'unknown'
                     CHECK (conn_state IN ('online','offline','degraded','unknown')),
    created_at       INTEGER NOT NULL
) STRICT;

-- Physical gateway units over time. The service maps an incoming serial to the current row,
-- then to the logical gateway. Replacing a box closes the old row and opens a new one.
CREATE TABLE gateway_hardware (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id),
    serial           TEXT    NOT NULL UNIQUE,          -- e.g. GW1B2511004
    platform         TEXT    NOT NULL DEFAULT 'cm4' CHECK (platform IN ('cm4','ubuntu-vm')),
    installed_at     INTEGER NOT NULL,
    removed_at       INTEGER,                          -- NULL = currently installed
    reason           TEXT    NOT NULL DEFAULT 'commissioned'
                     CHECK (reason IN ('commissioned','replaced')),
    changed_by       INTEGER REFERENCES user_account(id),
    CHECK (removed_at IS NULL OR removed_at >= installed_at)
) STRICT;
CREATE UNIQUE INDEX ux_gateway_hw_current ON gateway_hardware(gateway_id) WHERE removed_at IS NULL;

-- Any controller a gateway talks to: a fire panel (FACP), a BACnet controller, a Modbus meter,
-- an SNMP device... Devices/points hang off a controller. Fire is the only system in release 1.
CREATE TABLE controller (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id),
    space_id         INTEGER REFERENCES space(id),     -- where the controller is installed
    system           TEXT    NOT NULL DEFAULT 'fire'
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    protocol         TEXT    NOT NULL,                 -- 'simplex', 'bacnet', 'modbus', 'snmp'...
    ref              TEXT    NOT NULL,                 -- fire node no., BACnet device instance, Modbus unit id
    name             TEXT    NOT NULL,
    vendor           TEXT,
    model            TEXT,
    firmware_version TEXT,
    conn_state       TEXT    NOT NULL DEFAULT 'unknown'
                     CHECK (conn_state IN ('online','offline','unknown')),
    last_contact     INTEGER,
    UNIQUE (gateway_id, protocol, ref)
) STRICT;

-- Device classification: rules, aggregation, symbols and permissions key off these,
-- never off vendor strings. Vendor types are mapped once in vendor_type_map.
CREATE TABLE device_category (
    id               INTEGER PRIMARY KEY,
    code             TEXT    NOT NULL UNIQUE,          -- detector, manual_call_point, monitor_input...
    system           TEXT    NOT NULL DEFAULT 'fire'
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    name             TEXT    NOT NULL,
    is_physical      INTEGER NOT NULL DEFAULT 1 CHECK (is_physical IN (0,1)),  -- 0 = virtual/controller-generated point
    sort_order       INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE device_type (
    id                 INTEGER PRIMARY KEY,            -- 0 = unknown / unmapped
    code               TEXT    NOT NULL UNIQUE,        -- smoke_detector, heat_detector, aux_relay...
    device_category_id INTEGER NOT NULL REFERENCES device_category(id),
    name               TEXT    NOT NULL,
    has_analog         INTEGER NOT NULL DEFAULT 0 CHECK (has_analog IN (0,1)),   -- sensitivity/dirtiness trending
    can_disable        INTEGER NOT NULL DEFAULT 1 CHECK (can_disable IN (0,1)),
    can_test           INTEGER NOT NULL DEFAULT 0 CHECK (can_test IN (0,1)),
    default_symbol     TEXT                            -- icon used on floor plans
) STRICT;

-- Vendor/controller type string -> our device_type (stored upper-case, so 'High Speed Bus' and 'HIGH SPEED BUS' match)
CREATE TABLE vendor_type_map (
    id               INTEGER PRIMARY KEY,
    vendor           TEXT    NOT NULL,                 -- 'Simplex'
    vendor_type      TEXT    NOT NULL,                 -- e.g. 'SMOKE DETECTOR' (upper-case)
    device_type_id   INTEGER NOT NULL REFERENCES device_type(id),
    UNIQUE (vendor, vendor_type)
) STRICT;

CREATE TABLE device (
    id               INTEGER PRIMARY KEY,
    controller_id    INTEGER NOT NULL REFERENCES controller(id),
    address          TEXT    NOT NULL,                 -- normalised key, unique per controller:
                                                       --   fire 'L1-M35', BACnet 'AI:3', Modbus 'HR:40001'
    address_json     TEXT    NOT NULL DEFAULT '{}',    -- protocol parts, e.g. {"loop":1,"point":"M35"}
                                                       --   or {"object_type":"analogInput","instance":3}
    device_type_id   INTEGER NOT NULL DEFAULT 0 REFERENCES device_type(id),  -- our classification; raw vendor type is on device_hardware
    source_label     TEXT,                             -- label reported by the controller
    local_label      TEXT,                             -- commissioning label (requirement 20)
    space_id         INTEGER REFERENCES space(id),     -- logical location; plan position is in plan_placement
    attributes_json  TEXT    NOT NULL DEFAULT '{}',    -- raw vendor attributes, never guessed
    discovery_state  TEXT    NOT NULL DEFAULT 'present'
                     CHECK (discovery_state IN ('present','missing','removed')),
    created_at       INTEGER NOT NULL,
    UNIQUE (controller_id, address)
) STRICT;
CREATE INDEX ix_device_space ON device(space_id);
CREATE INDEX ix_device_type  ON device(device_type_id);

-- Physical device units and addresses over time. device (above) is the logical point and holds
-- the CURRENT controller/address used to match incoming events; this table keeps every unit
-- and address the point has had, so a replaced or readdressed device keeps all its history.
-- Telemetry trends and advisory baselines restart from the current row's installed_at.
CREATE TABLE device_hardware (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES device(id),
    controller_id    INTEGER NOT NULL REFERENCES controller(id),  -- address while this unit was installed
    address          TEXT    NOT NULL,
    address_json     TEXT    NOT NULL DEFAULT '{}',
    serial           TEXT,                             -- if the controller reports it
    model            TEXT,
    vendor_type      TEXT,                             -- raw type string reported by the controller (e.g. 'SMOKE DETECTOR');
                                                       -- the single source for unmapped-type review and re-mapping
    installed_at     INTEGER NOT NULL,
    removed_at       INTEGER,                          -- NULL = currently installed
    reason           TEXT    NOT NULL DEFAULT 'commissioned'
                     CHECK (reason IN ('commissioned','replaced','moved','readdressed')),
    changed_by       INTEGER REFERENCES user_account(id),
    CHECK (removed_at IS NULL OR removed_at >= installed_at)
) STRICT;
CREATE UNIQUE INDEX ux_device_hw_current ON device_hardware(device_id) WHERE removed_at IS NULL;
CREATE INDEX ix_device_hw_device ON device_hardware(device_id, installed_at);

-- Free-form site tags for grouping that types cannot express (e.g. 'kitchen', 'server room', 'critical')
CREATE TABLE device_tag (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    tag              TEXT    NOT NULL COLLATE NOCASE,
    UNIQUE (device_id, tag)
) STRICT;
CREATE INDEX ix_device_tag ON device_tag(tag);

-- Current state, one row per device (fast dashboard reads).
-- A device can be in several states at once (e.g. trouble + supervisory, or alarm + test),
-- so all active states are kept as a JSON array; primary_state is the most important one,
-- derived by the service from alarm_class precedence, and used for colours, sorting and counts.
CREATE TABLE device_state (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL UNIQUE REFERENCES device(id),
    states_json      TEXT    NOT NULL DEFAULT '["normal"]'   -- all active states, e.g. ["trouble","supervisory"]
                     CHECK (json_valid(states_json) AND json_type(states_json) = 'array'),
    primary_state    TEXT    NOT NULL DEFAULT 'normal',      -- highest-precedence entry of states_json
    is_disabled      INTEGER NOT NULL DEFAULT 0 CHECK (is_disabled IN (0,1)),
    is_stale         INTEGER NOT NULL DEFAULT 0 CHECK (is_stale IN (0,1)),
    analog_json      TEXT,                             -- latest sensitivity, dirtiness, values
    updated_src_time INTEGER,                          -- source time of the last state/value CHANGE
    updated_rcv_time INTEGER NOT NULL,                 -- receive time of the last state/value CHANGE
    last_seen_at     INTEGER                           -- receive time of the last message of any kind about this device,
                                                       -- even if nothing changed. Kept live in memory and written at most
                                                       -- once a minute per device. Not an offline signal for fire points
                                                       -- (panels report only on change); use controller/gateway health.
) STRICT;

-- State changes over time (requirement 17), subject to retention
CREATE TABLE device_state_history (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES device(id),
    old_states_json  TEXT    CHECK (old_states_json IS NULL OR json_valid(old_states_json)),
    new_states_json  TEXT    NOT NULL CHECK (json_valid(new_states_json)),
    new_primary_state TEXT   NOT NULL,                 -- for quick filtering of history
    src_time         INTEGER,
    rcv_time         INTEGER NOT NULL
) STRICT;
CREATE INDEX ix_dsh_device_time ON device_state_history(device_id, rcv_time);

-- Where a device, controller or gateway is drawn on a floor plan (requirements 31, 34, 39).
-- Separate from device.space_id so a plan can be replaced and placements re-confirmed,
-- and so one item can appear on more than one plan (e.g. floor plan and riser overview).
CREATE TABLE plan_placement (
    id               INTEGER PRIMARY KEY,
    floor_plan_id    INTEGER NOT NULL REFERENCES floor_plan(id) ON DELETE CASCADE,
    device_id        INTEGER REFERENCES device(id),
    controller_id    INTEGER REFERENCES controller(id),
    gateway_id       INTEGER REFERENCES gateway(id),
    x                REAL    NOT NULL CHECK (x BETWEEN 0 AND 1),   -- relative to plan width
    y                REAL    NOT NULL CHECK (y BETWEEN 0 AND 1),   -- relative to plan height
    rotation_deg     REAL    NOT NULL DEFAULT 0,
    symbol           TEXT,                             -- icon override; default comes from device type
    status           TEXT    NOT NULL DEFAULT 'placed'
                     CHECK (status IN ('placed','needs_review')),  -- needs_review after a plan is replaced
    placed_by        INTEGER REFERENCES user_account(id),
    placed_at        INTEGER NOT NULL,
    CHECK ((device_id IS NOT NULL) + (controller_id IS NOT NULL) + (gateway_id IS NOT NULL) = 1)
) STRICT;
CREATE UNIQUE INDEX ux_place_device  ON plan_placement(floor_plan_id, device_id)  WHERE device_id  IS NOT NULL;
CREATE UNIQUE INDEX ux_place_controller ON plan_placement(floor_plan_id, controller_id) WHERE controller_id IS NOT NULL;
CREATE UNIQUE INDEX ux_place_gateway ON plan_placement(floor_plan_id, gateway_id) WHERE gateway_id IS NOT NULL;
CREATE INDEX ix_place_device ON plan_placement(device_id);

-- ---------------------------------------------------------------------
-- 3. Alarm log (append-only, requirement 49) and active alarms
-- ---------------------------------------------------------------------
-- Alarm classes per system. Fire classes always have the highest precedence and
-- is_life_safety = 1, which drives the fast lane, sounds and display priority.
CREATE TABLE alarm_class (
    id               INTEGER PRIMARY KEY,
    system           TEXT    NOT NULL
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    code             TEXT    NOT NULL,                 -- fire, priority2, supervisory, trouble, high_temp...
    name             TEXT    NOT NULL,
    precedence       INTEGER NOT NULL,                 -- 1 = highest; fire = 1 always
    is_life_safety   INTEGER NOT NULL DEFAULT 0 CHECK (is_life_safety IN (0,1)),
    UNIQUE (system, code)
) STRICT;
CREATE TABLE event (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id),            -- logical gateway (history)
    gateway_hardware_id INTEGER NOT NULL REFERENCES gateway_hardware(id), -- physical box that sent it
    source_event_id  TEXT    NOT NULL,                 -- stable id or sequence from the gateway
    controller_id    INTEGER REFERENCES controller(id),
    device_id        INTEGER REFERENCES device(id),
    event_type       TEXT    NOT NULL CHECK (event_type IN ('alarm','restore','status')),
    alarm_class_id   INTEGER REFERENCES alarm_class(id),   -- set for alarm and restore events
    condition        TEXT,                             -- e.g. 'Sensor Dirty', 'Open Circuit' as reported
    src_time         INTEGER,                          -- source time (may be absent or skewed)
    rcv_time         INTEGER NOT NULL,                 -- service receive time
    is_late          INTEGER NOT NULL DEFAULT 0 CHECK (is_late IN (0,1)),  -- replayed from buffer
    raw_json         TEXT    NOT NULL,                 -- original payload for traceability
    UNIQUE (gateway_hardware_id, source_event_id),     -- duplicates harmless; a replacement box may restart its counter
    CHECK (event_type = 'status' OR alarm_class_id IS NOT NULL)
) STRICT;
-- Keep indexes on this hot table to a minimum (batch inserts)
CREATE INDEX ix_event_rcv      ON event(rcv_time);
CREATE INDEX ix_event_device   ON event(device_id, rcv_time);

-- One row per alarm occurrence; tracks lifecycle for the live view
CREATE TABLE alarm (
    id               INTEGER PRIMARY KEY,
    raised_event_id  INTEGER NOT NULL UNIQUE REFERENCES event(id),
    cleared_event_id INTEGER REFERENCES event(id),
    site_id          INTEGER NOT NULL REFERENCES site(id),
    controller_id    INTEGER REFERENCES controller(id),
    device_id        INTEGER REFERENCES device(id),
    alarm_class_id   INTEGER NOT NULL REFERENCES alarm_class(id),
    precedence       INTEGER NOT NULL,                 -- copied from alarm_class at insert, for fast ordering
    state            TEXT    NOT NULL DEFAULT 'active'
                     CHECK (state IN ('active','acknowledged','cleared')),
    raised_at        INTEGER NOT NULL,
    acked_by         INTEGER REFERENCES user_account(id),
    acked_at         INTEGER,
    cleared_at       INTEGER,
    note             TEXT                              -- operator note (requirement 13)
) STRICT;
CREATE INDEX ix_alarm_open ON alarm(state, precedence, raised_at) WHERE state <> 'cleared';
CREATE INDEX ix_alarm_site ON alarm(site_id, raised_at);
CREATE INDEX ix_alarm_cleared_event ON alarm(cleared_event_id) WHERE cleared_event_id IS NOT NULL;  -- retention: "is this event still referenced?"

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

-- ---------------------------------------------------------------------
-- 4. Commands to controllers and devices (silence, reset, disable, later setpoints...)
-- ---------------------------------------------------------------------
-- The same safety rules (confirm, expiry, never retry, audit) apply to every command type.
CREATE TABLE command_type (
    id               INTEGER PRIMARY KEY,
    system           TEXT    NOT NULL
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    code             TEXT    NOT NULL,                 -- silence, reset, disable_device, write_setpoint...
    name             TEXT    NOT NULL,
    target           TEXT    NOT NULL CHECK (target IN ('controller','device')),
    permission_id    INTEGER NOT NULL REFERENCES permission(id),
    pin_policy       TEXT    NOT NULL DEFAULT 'never'
                     CHECK (pin_policy IN ('never','if_enabled','always')),  -- if_enabled = site setting (req 63)
    expiry_sec       INTEGER NOT NULL DEFAULT 30,
    allow_schedule   INTEGER NOT NULL DEFAULT 0 CHECK (allow_schedule IN (0,1)),
                     -- 1 = may run from a schedule. Never for life-safety actions (silence, reset,
                     -- disable): those always need a person at the screen.
    UNIQUE (system, code),
    CHECK (allow_schedule = 0 OR pin_policy = 'never')   -- a schedule cannot type a PIN
) STRICT;

-- Recurring commands, e.g. sync the FACP clock daily, poll detector analogue values nightly,
-- run discovery weekly. Only command types with allow_schedule = 1 can be scheduled.
-- Safety: a run that is due while the target is offline, or while a life-safety alarm is
-- active (if skip_if_alarm_active), is SKIPPED and recorded, never queued for later.
CREATE TABLE command_schedule (
    id                   INTEGER PRIMARY KEY,
    name                 TEXT    NOT NULL,
    command_type_id      INTEGER NOT NULL REFERENCES command_type(id),
    site_id              INTEGER NOT NULL REFERENCES site(id),
    controller_id        INTEGER REFERENCES controller(id),     -- one controller, or
    device_id            INTEGER REFERENCES device(id),         -- one device, or
    target_filter_json   TEXT,                                  -- many devices, e.g. {"device_type":"smoke_detector","space_id":105}
    params_json          TEXT    NOT NULL DEFAULT '{}',         -- command parameters
    cron_expr            TEXT,                                  -- e.g. '0 3 * * *' = 03:00 daily, in the site timezone
    interval_sec         INTEGER CHECK (interval_sec IS NULL OR interval_sec >= 60),
    window_start         TEXT,                                  -- optional allowed window, 'HH:MM' local time
    window_end           TEXT,
    skip_if_alarm_active INTEGER NOT NULL DEFAULT 1 CHECK (skip_if_alarm_active IN (0,1)),
    max_targets_per_run  INTEGER NOT NULL DEFAULT 500,          -- spreads large device commands over time
    enabled              INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    last_run_at          INTEGER,
    next_run_at          INTEGER,                               -- computed by the service from cron/interval
    created_by           INTEGER NOT NULL REFERENCES user_account(id),
    created_at           INTEGER NOT NULL,
    approved_by          INTEGER REFERENCES user_account(id),   -- second person, if site policy requires
    CHECK ((cron_expr IS NOT NULL) + (interval_sec IS NOT NULL) = 1),
    CHECK ((controller_id IS NOT NULL) + (device_id IS NOT NULL) + (target_filter_json IS NOT NULL) = 1),
    CHECK (target_filter_json IS NULL OR json_valid(target_filter_json)),
    CHECK (json_valid(params_json))
) STRICT;
CREATE INDEX ix_schedule_due ON command_schedule(next_run_at) WHERE enabled = 1;

-- Refuse schedules for command types that may not be scheduled
CREATE TRIGGER trg_schedule_allowed BEFORE INSERT ON command_schedule
WHEN (SELECT allow_schedule FROM command_type WHERE id = NEW.command_type_id) <> 1
BEGIN SELECT RAISE(ABORT, 'this command type cannot be scheduled'); END;
CREATE TRIGGER trg_schedule_allowed_upd BEFORE UPDATE OF command_type_id ON command_schedule
WHEN (SELECT allow_schedule FROM command_type WHERE id = NEW.command_type_id) <> 1
BEGIN SELECT RAISE(ABORT, 'this command type cannot be scheduled'); END;

-- One row per time a schedule fired (or was skipped)
CREATE TABLE schedule_run (
    id                   INTEGER PRIMARY KEY,
    command_schedule_id  INTEGER NOT NULL REFERENCES command_schedule(id),
    due_at               INTEGER NOT NULL,
    started_at           INTEGER,
    finished_at          INTEGER,
    status               TEXT    NOT NULL
                         CHECK (status IN ('running','done','partial','skipped','failed')),
    skip_reason          TEXT    CHECK (skip_reason IS NULL OR skip_reason IN
                         ('target_offline','alarm_active','outside_window','disabled','previous_run_active')),
    commands_sent        INTEGER NOT NULL DEFAULT 0,
    commands_succeeded   INTEGER NOT NULL DEFAULT 0,
    commands_failed      INTEGER NOT NULL DEFAULT 0,
    CHECK (status <> 'skipped' OR skip_reason IS NOT NULL)
) STRICT;
CREATE INDEX ix_schedule_run_sched ON schedule_run(command_schedule_id, due_at);

CREATE TABLE command (
    id               INTEGER PRIMARY KEY,
    correlation_id   TEXT    NOT NULL UNIQUE,          -- sent to the gateway, echoed in the result
    user_id          INTEGER NOT NULL REFERENCES user_account(id),
    session_id       INTEGER REFERENCES session(id),
    command_type_id  INTEGER NOT NULL REFERENCES command_type(id),
    controller_id    INTEGER REFERENCES controller(id),
    device_id        INTEGER REFERENCES device(id),
    pin_verified     INTEGER NOT NULL DEFAULT 0 CHECK (pin_verified IN (0,1)),
    status           TEXT    NOT NULL
                     CHECK (status IN ('refused','pending','success','rejected','failed','timeout')),
    status_reason    TEXT,
    requested_at     INTEGER NOT NULL,
    expires_at       INTEGER NOT NULL,
    completed_at     INTEGER,
    raw_json         TEXT    NOT NULL,                 -- original request sent to the gateway
    schedule_run_id  INTEGER REFERENCES schedule_run(id) -- set when a schedule sent it; user_id = schedule owner
) STRICT;
CREATE INDEX ix_command_pending ON command(status, expires_at) WHERE status = 'pending';
CREATE INDEX ix_command_schedule_run ON command(schedule_run_id) WHERE schedule_run_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 5. Users, roles, permissions, scope and sessions
-- ---------------------------------------------------------------------
CREATE TABLE user_account (
    id               INTEGER PRIMARY KEY,
    username         TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    display_name     TEXT    NOT NULL,
    auth_type        TEXT    NOT NULL CHECK (auth_type IN ('windows','local')),
    windows_sid      TEXT    UNIQUE,                   -- for Windows/AD sign-on
    password_hash    TEXT,                             -- Argon2id encoded string (local accounts)
    pin_hash         TEXT,                             -- Argon2id; set at first sign-in
    is_fallback      INTEGER NOT NULL DEFAULT 0 CHECK (is_fallback IN (0,1)),  -- requirement 61
    status           TEXT    NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    failed_attempts  INTEGER NOT NULL DEFAULT 0,
    locked_until     INTEGER,
    ui_prefs_json    TEXT    NOT NULL DEFAULT '{}',    -- theme, language
    created_at       INTEGER NOT NULL,
    CHECK (auth_type = 'windows' OR password_hash IS NOT NULL)
) STRICT;

CREATE TABLE role (
    id               INTEGER PRIMARY KEY,
    name             TEXT    NOT NULL UNIQUE,          -- Viewer, Operator, Engineer, Administrator
    is_builtin       INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0,1))
) STRICT;

CREATE TABLE permission (
    id               INTEGER PRIMARY KEY,
    code             TEXT    NOT NULL UNIQUE,          -- e.g. alarm.ack, panel.silence, panel.reset,View Floor Plan
    description      TEXT    NOT NULL
) STRICT;

CREATE TABLE role_permission (
    id               INTEGER PRIMARY KEY,
    role_id          INTEGER NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    permission_id    INTEGER NOT NULL REFERENCES permission(id),
    UNIQUE (role_id, permission_id)
) STRICT;

-- Role assignments with their scope (requirements 56, 59): a user holds a role
-- for a whole tenant, one site, or one space and everything beneath it.
--   tenant only            -> role applies across the tenant
--   tenant + site          -> role applies to that site
--   tenant + site + space  -> role applies to that space and its child spaces
--                             (e.g. Operator for Floor 16, or for office unit 16-02)
-- A user may hold several assignments (e.g. Viewer for the site, Operator for Floor 16).
CREATE TABLE user_role (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id) ON DELETE CASCADE,
    role_id          INTEGER NOT NULL REFERENCES role(id),
    tenant_id        INTEGER NOT NULL REFERENCES tenant(id),
    site_id          INTEGER REFERENCES site(id),
    space_id         INTEGER REFERENCES space(id),
    granted_by       INTEGER REFERENCES user_account(id),
    granted_at       INTEGER NOT NULL,
    CHECK (space_id IS NULL OR site_id IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX ux_user_role_scope
    ON user_role(user_id, role_id, tenant_id, IFNULL(site_id, 0), IFNULL(space_id, 0));

-- AD group to role mapping (requirement 66), with the same optional scope
CREATE TABLE directory_group_role (
    id               INTEGER PRIMARY KEY,
    group_sid        TEXT    NOT NULL,
    role_id          INTEGER NOT NULL REFERENCES role(id),
    tenant_id        INTEGER NOT NULL REFERENCES tenant(id),
    site_id          INTEGER REFERENCES site(id),
    space_id         INTEGER REFERENCES space(id),
    CHECK (space_id IS NULL OR site_id IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX ux_group_role_scope
    ON directory_group_role(group_sid, role_id, tenant_id, IFNULL(site_id, 0), IFNULL(space_id, 0));

-- Keep scopes consistent: the site must belong to the tenant, and the space to the site
CREATE TRIGGER trg_user_role_scope BEFORE INSERT ON user_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'user_role scope: site/space does not belong to the tenant/site'); END;
CREATE TRIGGER trg_user_role_scope_upd BEFORE UPDATE ON user_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'user_role scope: site/space does not belong to the tenant/site'); END;
CREATE TRIGGER trg_group_role_scope BEFORE INSERT ON directory_group_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'directory_group_role scope: site/space does not belong to the tenant/site'); END;

CREATE TABLE session (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id),
    token_hash       TEXT    NOT NULL UNIQUE,          -- SHA-256 of the random token; token never stored
    client_kind      TEXT    NOT NULL CHECK (client_kind IN ('desktop','web')),
    client_host      TEXT,
    started_at       INTEGER NOT NULL,
    last_activity    INTEGER NOT NULL,
    locked           INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0,1)),
    ended_at         INTEGER,
    end_reason       TEXT    CHECK (end_reason IN ('logout','expired','pin_failures','admin','service_restart'))
) STRICT;
CREATE INDEX ix_session_open ON session(user_id) WHERE ended_at IS NULL;

-- ---------------------------------------------------------------------
-- 6. Audit log (append-only, tamper-evident; requirement 50)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY,
    at               INTEGER NOT NULL,
    user_id          INTEGER REFERENCES user_account(id),
    session_id       INTEGER REFERENCES session(id),
    client_host      TEXT,
    action           TEXT    NOT NULL,                 -- e.g. auth.login, auth.pin_fail, panel.silence, settings.change
    target_type      TEXT,
    target_id        TEXT,
    outcome          TEXT    NOT NULL CHECK (outcome IN ('success','refused','failed')),
    before_json      TEXT,                             -- non-secret previous values
    after_json       TEXT,
    detail           TEXT,
    prev_hash        TEXT    NOT NULL,                 -- row_hash of the previous row
    row_hash         TEXT    NOT NULL                  -- SHA-256 over this row's fields + prev_hash
) STRICT;
CREATE INDEX ix_audit_at ON audit_log(at);

-- No update or delete at any permission level
CREATE TRIGGER trg_audit_no_update BEFORE UPDATE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
CREATE TRIGGER trg_audit_no_delete BEFORE DELETE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;

-- Alarm log rows are never edited; deletion only by the retention job (see section 8)
CREATE TRIGGER trg_event_no_update BEFORE UPDATE ON event
BEGIN SELECT RAISE(ABORT, 'event is append-only'); END;

-- ---------------------------------------------------------------------
-- 7. Integrity: quarantine and gateway health
-- ---------------------------------------------------------------------
-- Messages that failed validation; never silently discarded (requirement 95)
CREATE TABLE quarantine (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER REFERENCES gateway(id),
    topic            TEXT    NOT NULL,
    payload          BLOB    NOT NULL,
    error            TEXT    NOT NULL,
    rcv_time         INTEGER NOT NULL,
    reviewed_by      INTEGER REFERENCES user_account(id),
    reviewed_at      INTEGER
) STRICT;

CREATE TABLE gateway_health (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id),
    rcv_time         INTEGER NOT NULL,
    cpu_pct          REAL,
    mem_pct          REAL,
    disk_pct         REAL,
    buffer_depth     INTEGER,
    detail_json      TEXT
) STRICT;
CREATE INDEX ix_gwh_gateway_time ON gateway_health(gateway_id, rcv_time);

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

-- ---------------------------------------------------------------------
-- 9. Licence and acceptance (requirements 70-74)
-- ---------------------------------------------------------------------
CREATE TABLE licence (
    id               INTEGER PRIMARY KEY,
    licence_key_enc  BLOB    NOT NULL,                 -- DPAPI-encrypted
    entitlements_json TEXT   NOT NULL,
    activated_at     INTEGER NOT NULL,
    activation_mode  TEXT    NOT NULL CHECK (activation_mode IN ('online','offline'))
) STRICT;

CREATE TABLE document_acceptance (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id),
    document         TEXT    NOT NULL CHECK (document IN ('terms','privacy')),
    doc_version      TEXT    NOT NULL,
    accepted_at      INTEGER NOT NULL
) STRICT;

