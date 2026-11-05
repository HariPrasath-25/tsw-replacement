-- Module 03: events_alarms — alarm classes, the append-only alarm log, active alarms (M1: P4, D9, D10, D11, P8)

-- ---------------------------------------------------------------------
-- 3. Alarm log (append-only, requirement 49) and active alarms
-- ---------------------------------------------------------------------
-- Alarm classes per system (req 6). Fire classes always have the highest precedence and
-- is_life_safety = 1, which drives the fast lane, sounds and display priority.
CREATE TABLE alarm_class (
    id               INTEGER PRIMARY KEY,
    system           TEXT    NOT NULL
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    code             TEXT    NOT NULL,                 -- fire, priority2, supervisory, trouble, high_temp...
    name             TEXT    NOT NULL,
    precedence       INTEGER NOT NULL,                 -- 1 = highest; fire = 1 always
    is_life_safety   INTEGER NOT NULL DEFAULT 0 CHECK (is_life_safety IN (0,1)),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (system, code)
) STRICT;

-- Every message received from a source (req 49, 97). Append-only; ids leave the DB (archive) so AUTOINCREMENT.
-- All FKs RESTRICT: history must never lose its source. FK indexes beyond the minimum are deferred to M5 (ADR-002, T7).
CREATE TABLE event (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id) ON DELETE RESTRICT,            -- logical gateway (history)
    gateway_hardware_id INTEGER NOT NULL REFERENCES gateway_hardware(id) ON DELETE RESTRICT, -- physical box that sent it
    source_event_id  TEXT    NOT NULL,                 -- stable id or sequence from the gateway
    controller_id    INTEGER REFERENCES controller(id) ON DELETE RESTRICT,
    device_id        INTEGER REFERENCES device(id) ON DELETE RESTRICT,
    event_type       TEXT    NOT NULL CHECK (event_type IN ('alarm','restore','status')),
    alarm_class_id   INTEGER REFERENCES alarm_class(id) ON DELETE RESTRICT,   -- set for alarm and restore events
    condition        TEXT,                             -- e.g. 'Sensor Dirty', 'Open Circuit' as reported
    src_time         INTEGER CHECK (src_time > 0),     -- source time (may be absent or skewed)
    rcv_time         INTEGER NOT NULL CHECK (rcv_time > 0),  -- service receive time
    is_late          INTEGER NOT NULL DEFAULT 0 CHECK (is_late IN (0,1)),  -- replayed from buffer
    raw_json         TEXT    NOT NULL                  -- original payload for traceability
                     CHECK (json_valid(raw_json) AND json_type(raw_json) = 'object'),
    UNIQUE (gateway_hardware_id, source_event_id),     -- duplicates harmless; a replacement box may restart its counter
    CHECK (event_type = 'status' OR alarm_class_id IS NOT NULL)
) STRICT;
-- Keep indexes on this hot table to a minimum (batch inserts)
CREATE INDEX ix_event_rcv      ON event(rcv_time);
CREATE INDEX ix_event_device   ON event(device_id, rcv_time);

-- One row per alarm occurrence; tracks lifecycle for the live view (req 5, 8, 13). Ids leave the DB: AUTOINCREMENT.
CREATE TABLE alarm (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    raised_event_id  INTEGER NOT NULL UNIQUE REFERENCES event(id) ON DELETE RESTRICT,
    cleared_event_id INTEGER REFERENCES event(id) ON DELETE RESTRICT,
    site_id          INTEGER NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
    controller_id    INTEGER REFERENCES controller(id) ON DELETE RESTRICT,
    device_id        INTEGER REFERENCES device(id) ON DELETE RESTRICT,
    alarm_class_id   INTEGER NOT NULL REFERENCES alarm_class(id) ON DELETE RESTRICT,
    precedence       INTEGER NOT NULL,                 -- copied from alarm_class at insert, for fast ordering
    state            TEXT    NOT NULL DEFAULT 'active'
                     CHECK (state IN ('active','acknowledged','cleared')),
    raised_at        INTEGER NOT NULL CHECK (raised_at > 0),
    acked_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    acked_at         INTEGER CHECK (acked_at > 0),
    cleared_at       INTEGER CHECK (cleared_at > 0),
    note             TEXT                              -- operator note (requirement 13)
) STRICT;
CREATE INDEX ix_alarm_open ON alarm(state, precedence, raised_at) WHERE state <> 'cleared';
CREATE INDEX ix_alarm_site ON alarm(site_id, raised_at);
CREATE INDEX ix_alarm_cleared_event ON alarm(cleared_event_id) WHERE cleared_event_id IS NOT NULL;  -- retention: "is this event still referenced?"

-- Alarm log rows are never edited; deletion only by the retention job (gate added in M5/M11)
CREATE TRIGGER trg_event_no_update BEFORE UPDATE ON event
BEGIN SELECT RAISE(ABORT, 'event is append-only'); END;
