-- Module 05: commands (split verbatim from Draft v2 in M0; source of truth from here on)

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
