-- Module 05: commands — command types, schedules, schedule runs, the command log (M1: P4, D9, D10, D11, P8; M2: N1, N6)

-- ---------------------------------------------------------------------
-- 4. Commands to controllers and devices (silence, reset, disable, later setpoints...)
-- ---------------------------------------------------------------------
-- The same safety rules (confirm, expiry, never retry, audit) apply to every command type (req 9-12, 63).
CREATE TABLE command_type (
    id               INTEGER PRIMARY KEY,
    system_id        INTEGER NOT NULL REFERENCES system(id) ON DELETE RESTRICT,  -- N1 (was a CHECK list)
    code             TEXT    NOT NULL,                 -- silence, reset, disable_device, write_setpoint...
    name             TEXT    NOT NULL,
    name_key         TEXT    UNIQUE                    -- N6, T14
                     CHECK (name_key GLOB '[a-z]*' AND name_key NOT GLOB '*[^a-z0-9._]*'),
    target           TEXT    NOT NULL CHECK (target IN ('controller','device')),
    permission_id    INTEGER NOT NULL REFERENCES permission(id) ON DELETE RESTRICT,
    pin_policy       TEXT    NOT NULL DEFAULT 'never'
                     CHECK (pin_policy IN ('never','if_enabled','always')),  -- if_enabled = site setting (req 63)
    expiry_sec       INTEGER NOT NULL DEFAULT 30 CHECK (expiry_sec > 0),
    can_schedule     INTEGER NOT NULL DEFAULT 0 CHECK (can_schedule IN (0,1)),
                     -- 1 = may run from a schedule. Never for life-safety actions (silence, reset,
                     -- disable): those always need a person at the screen.
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (system_id, code),                          -- leading system_id also serves the FK
    CHECK (can_schedule = 0 OR pin_policy = 'never')   -- a schedule cannot type a PIN
) STRICT;
CREATE INDEX ix_command_type_permission_id ON command_type(permission_id);

-- Recurring commands, e.g. sync the FACP clock daily, poll detector analogue values nightly,
-- run discovery weekly. Only command types with can_schedule = 1 can be scheduled.
-- Safety: a run that is due while the target is offline, or while a life-safety alarm is
-- active (if is_skip_if_alarm_active), is SKIPPED and recorded, never queued for later.
-- Not in release 1 scope (G20): structure kept, no service logic yet.
CREATE TABLE command_schedule (
    id                   INTEGER PRIMARY KEY,
    name                 TEXT    NOT NULL,
    command_type_id      INTEGER NOT NULL REFERENCES command_type(id) ON DELETE RESTRICT,
    site_id              INTEGER NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
    controller_id        INTEGER REFERENCES controller(id) ON DELETE RESTRICT,  -- one controller, or
    device_id            INTEGER REFERENCES device(id) ON DELETE RESTRICT,      -- one device, or
    target_filter_json   TEXT,                                  -- many devices, e.g. {"device_type":"smoke_detector","space_id":105}
    params_json          TEXT    NOT NULL DEFAULT '{}',         -- command parameters
    cron_expr            TEXT,                                  -- e.g. '0 3 * * *' = 03:00 daily, in the site timezone
    interval_sec         INTEGER CHECK (interval_sec IS NULL OR interval_sec >= 60),
    window_start         TEXT,                                  -- optional allowed window, 'HH:MM' local time
    window_end           TEXT,
    is_skip_if_alarm_active INTEGER NOT NULL DEFAULT 1 CHECK (is_skip_if_alarm_active IN (0,1)),
    max_targets_per_run  INTEGER NOT NULL DEFAULT 500,          -- spreads large device commands over time
    is_enabled           INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0,1)),
    last_run_at          INTEGER CHECK (last_run_at > 0),
    next_run_at          INTEGER CHECK (next_run_at > 0),       -- computed by the service from cron/interval
    created_by_user_account_id  INTEGER NOT NULL REFERENCES user_account(id) ON DELETE RESTRICT,
    created_at           INTEGER NOT NULL CHECK (created_at > 0),
    approved_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,  -- second person, if site policy requires
    updated_at           INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id  INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version          INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK ((cron_expr IS NOT NULL) + (interval_sec IS NOT NULL) = 1),
    CHECK ((controller_id IS NOT NULL) + (device_id IS NOT NULL) + (target_filter_json IS NOT NULL) = 1),
    CHECK (target_filter_json IS NULL OR (json_valid(target_filter_json) AND json_type(target_filter_json) = 'object')),
    CHECK (json_valid(params_json) AND json_type(params_json) = 'object'),
    CHECK (window_start IS NULL OR (window_start GLOB '[0-2][0-9]:[0-5][0-9]' AND window_start <= '23:59')),
    CHECK (window_end IS NULL OR (window_end GLOB '[0-2][0-9]:[0-5][0-9]' AND window_end <= '23:59')),
    CHECK ((window_start IS NULL) = (window_end IS NULL))
) STRICT;
CREATE INDEX ix_command_schedule_next_run_at ON command_schedule(next_run_at) WHERE is_enabled = 1;
CREATE INDEX ix_command_schedule_command_type_id ON command_schedule(command_type_id);
CREATE INDEX ix_command_schedule_site_id ON command_schedule(site_id);
CREATE INDEX ix_command_schedule_controller_id ON command_schedule(controller_id) WHERE controller_id IS NOT NULL;
CREATE INDEX ix_command_schedule_device_id ON command_schedule(device_id) WHERE device_id IS NOT NULL;

-- Refuse schedules for command types that may not be scheduled
CREATE TRIGGER trg_command_schedule_allowed BEFORE INSERT ON command_schedule
WHEN (SELECT can_schedule FROM command_type WHERE id = NEW.command_type_id) <> 1
BEGIN SELECT RAISE(ABORT, 'this command type cannot be scheduled'); END;
CREATE TRIGGER trg_command_schedule_allowed_upd BEFORE UPDATE OF command_type_id ON command_schedule
WHEN (SELECT can_schedule FROM command_type WHERE id = NEW.command_type_id) <> 1
BEGIN SELECT RAISE(ABORT, 'this command type cannot be scheduled'); END;

-- One row per time a schedule fired (or was skipped). History: RESTRICT.
CREATE TABLE schedule_run (
    id                   INTEGER PRIMARY KEY,
    command_schedule_id  INTEGER NOT NULL REFERENCES command_schedule(id) ON DELETE RESTRICT,
    due_at               INTEGER NOT NULL CHECK (due_at > 0),
    started_at           INTEGER CHECK (started_at > 0),
    finished_at          INTEGER CHECK (finished_at > 0),
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

-- Command log (req 9-12, 50, T2). Ids leave the DB: AUTOINCREMENT. All FKs RESTRICT; FK indexes deferred to M6 (ADR-002).
CREATE TABLE command (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    correlation_id   TEXT    NOT NULL UNIQUE           -- lowercase UUID, sent to the gateway, echoed in the result
                     CHECK (length(correlation_id) = 36
                            AND correlation_id GLOB '????????-????-????-????-????????????'
                            AND replace(correlation_id, '-', '') NOT GLOB '*[^0-9a-f]*'),
    user_id          INTEGER NOT NULL REFERENCES user_account(id) ON DELETE RESTRICT,
    session_id       INTEGER REFERENCES session(id) ON DELETE RESTRICT,
    command_type_id  INTEGER NOT NULL REFERENCES command_type(id) ON DELETE RESTRICT,
    controller_id    INTEGER REFERENCES controller(id) ON DELETE RESTRICT,
    device_id        INTEGER REFERENCES device(id) ON DELETE RESTRICT,
    is_pin_verified  INTEGER NOT NULL DEFAULT 0 CHECK (is_pin_verified IN (0,1)),
    status           TEXT    NOT NULL
                     CHECK (status IN ('refused','pending','success','rejected','failed','timeout')),
    status_reason    TEXT,
    requested_at     INTEGER NOT NULL CHECK (requested_at > 0),
    expires_at       INTEGER NOT NULL CHECK (expires_at > 0),
    completed_at     INTEGER CHECK (completed_at > 0),
    raw_json         TEXT    NOT NULL                  -- original request sent to the gateway
                     CHECK (json_valid(raw_json) AND json_type(raw_json) = 'object'),
    schedule_run_id  INTEGER REFERENCES schedule_run(id) ON DELETE RESTRICT -- set when a schedule sent it; user_id = schedule owner
) STRICT;
CREATE INDEX ix_command_pending ON command(status, expires_at) WHERE status = 'pending';
CREATE INDEX ix_command_schedule_run ON command(schedule_run_id) WHERE schedule_run_id IS NOT NULL;
