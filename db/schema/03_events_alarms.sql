-- Module 03: events_alarms — alarm classes, the append-only alarm log, active alarms (M1: P4, D9, D10, D11, P8; M2: N1, N6, G9)

-- ---------------------------------------------------------------------
-- 3. Alarm log (append-only, requirement 49) and active alarms
-- ---------------------------------------------------------------------
-- Alarm classes per system (req 6, 7). Fire classes always have the highest precedence and
-- is_life_safety = 1, which drives the fast lane, sounds and display priority.
-- The four fire classes are seeded (db/seed/02_alarm.sql, is_builtin = 1): Fire 1, Priority 2 2,
-- Supervisory 3, Trouble 4. Their identity and order are fixed (req 6: "precedence order is fixed"),
-- enforced by trg_alarm_class_fire_immutable and trg_alarm_class_builtin_no_delete.
CREATE TABLE alarm_class (
    id               INTEGER PRIMARY KEY,
    system_id        INTEGER NOT NULL REFERENCES system(id) ON DELETE RESTRICT,  -- N1 (was a CHECK list)
    code             TEXT    NOT NULL,                 -- fire, priority2, supervisory, trouble, high_temp...
    name             TEXT    NOT NULL,
    name_key         TEXT    UNIQUE                    -- N6, T14; the UI pairs it with colour + non-colour indicator (req 7)
                     CHECK (name_key GLOB '[a-z]*' AND name_key NOT GLOB '*[^a-z0-9._]*'),
    precedence       INTEGER NOT NULL CHECK (precedence >= 1),  -- 1 = highest; fire = 1 always
    is_life_safety   INTEGER NOT NULL DEFAULT 0 CHECK (is_life_safety IN (0,1)),
    is_builtin       INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0,1)),  -- 1 = seeded; cannot be deleted
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (system_id, code)                           -- leading system_id also serves the FK
) STRICT;
-- Precedence is unique within a system, so ordering is never ambiguous (req 6).
CREATE UNIQUE INDEX ux_alarm_class_system_id_precedence ON alarm_class(system_id, precedence);

-- Fire alarm classes: code, precedence, life-safety flag, system and built-in flag are immutable (req 6).
-- name, name_key and audit columns stay editable (wording, translation).
CREATE TRIGGER trg_alarm_class_fire_immutable
BEFORE UPDATE OF system_id, code, precedence, is_life_safety, is_builtin ON alarm_class
WHEN OLD.system_id = (SELECT id FROM system WHERE code = 'fire')
 AND (NEW.system_id IS NOT OLD.system_id OR NEW.code IS NOT OLD.code OR NEW.precedence IS NOT OLD.precedence
      OR NEW.is_life_safety IS NOT OLD.is_life_safety OR NEW.is_builtin IS NOT OLD.is_builtin)
BEGIN SELECT RAISE(ABORT, 'alarm_class: fire class code/precedence/is_life_safety are fixed (req 6)'); END;

-- Seeded classes cannot be deleted (req 6: one shared definition).
CREATE TRIGGER trg_alarm_class_builtin_no_delete
BEFORE DELETE ON alarm_class
WHEN OLD.is_builtin = 1
BEGIN SELECT RAISE(ABORT, 'alarm_class: built-in class cannot be deleted'); END;

-- Condition dictionary (G9, req 41, 43). The 8 req-41 conditions are seeded (db/seed/02_alarm.sql).
-- A condition a source reports that is not in the list is inserted on first sight with
-- is_reported_unknown = 1, so it is counted under its reported name, never discarded (req 41).
-- First-sight pattern (ADR-006), inside the ingest transaction, before the event INSERT:
--   INSERT INTO condition (raw_name, is_reported_unknown, created_at, updated_at)
--     VALUES (:raw, 1, :now, :now) ON CONFLICT (match_key) DO NOTHING;
--   SELECT id FROM condition WHERE match_key = upper(trim(:raw));
-- (RETURNING yields no row on conflict, hence the SELECT.) Matching is case-insensitive via match_key.
CREATE TABLE condition (
    id               INTEGER PRIMARY KEY,
    code             TEXT    UNIQUE,                   -- head_missing, no_answer...; NULL for reported-unknown rows
    raw_name         TEXT    NOT NULL,                 -- as reported, e.g. 'Sensor Dirty'
    match_key        TEXT    NOT NULL GENERATED ALWAYS AS (upper(trim(raw_name))) STORED,  -- normalised lookup key
    is_reported_unknown INTEGER NOT NULL DEFAULT 0 CHECK (is_reported_unknown IN (0,1)),  -- 1 = first seen at runtime
    name_key         TEXT    UNIQUE                    -- N6, T14; NULL = display raw_name
                     CHECK (name_key GLOB '[a-z]*' AND name_key NOT GLOB '*[^a-z0-9._]*'),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK (is_reported_unknown = 1 OR (code IS NOT NULL AND name_key IS NOT NULL))  -- known conditions are translatable
) STRICT;
CREATE UNIQUE INDEX ux_condition_match_key ON condition(match_key);

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
    condition_id     INTEGER REFERENCES condition(id) ON DELETE RESTRICT,  -- G9 (was free text); raw text stays in raw_json
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
