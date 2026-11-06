-- Seed 02: alarm — alarm classes, device state codes, condition dictionary (M2: G9, N6; req 6, 41)
--
-- Idempotent: every INSERT is ON CONFLICT DO NOTHING. Fixed ids. Timestamps = 2026-11-06T00:00:00Z.

-- Fire alarm classes (req 6): Fire, Priority 2, Supervisory, Trouble in descending precedence.
-- All four are life safety (approved 2026-11-06, ADR-007) and built in: identity and order are
-- fixed by trg_alarm_class_fire_immutable and trg_alarm_class_builtin_no_delete.
INSERT INTO alarm_class (id, system_id, code, name, name_key, precedence, is_life_safety, is_builtin, created_at, updated_at) VALUES
    (1, 1, 'fire',        'Fire',        'alarm_class.fire',        1, 1, 1, 1793923200000, 1793923200000),
    (2, 1, 'priority2',   'Priority 2',  'alarm_class.priority2',   2, 1, 1, 1793923200000, 1793923200000),
    (3, 1, 'supervisory', 'Supervisory', 'alarm_class.supervisory', 3, 1, 1, 1793923200000, 1793923200000),
    (4, 1, 'trouble',     'Trouble',     'alarm_class.trouble',     4, 1, 1, 1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;

-- Device state codes (used by device_state from M4). Proposed list, ADR-008: the four alarm
-- types keep req 6 order; then disabled (req 19), test, missing (req 18), unknown, normal.
INSERT INTO device_state_code (id, code, precedence, is_alarm, name_key, created_at, updated_at) VALUES
    (1, 'fire',        1,  1, 'device_state.fire',        1793923200000, 1793923200000),
    (2, 'priority2',   2,  1, 'device_state.priority2',   1793923200000, 1793923200000),
    (3, 'supervisory', 3,  1, 'device_state.supervisory', 1793923200000, 1793923200000),
    (4, 'trouble',     4,  1, 'device_state.trouble',     1793923200000, 1793923200000),
    (5, 'disabled',    5,  0, 'device_state.disabled',    1793923200000, 1793923200000),
    (6, 'test',        6,  0, 'device_state.test',        1793923200000, 1793923200000),
    (7, 'missing',     7,  0, 'device_state.missing',     1793923200000, 1793923200000),
    (8, 'unknown',     8,  0, 'device_state.unknown',     1793923200000, 1793923200000),
    (9, 'normal',      99, 0, 'device_state.normal',      1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;

-- Conditions (req 41): the eight from the gateway interface specification, each tracked separately.
-- Unknown reported conditions are added at runtime with is_reported_unknown = 1 (ADR-006).
INSERT INTO condition (id, code, raw_name, is_reported_unknown, name_key, created_at, updated_at) VALUES
    (1, 'head_missing',           'Head Missing',           0, 'condition.head_missing',           1793923200000, 1793923200000),
    (2, 'no_answer',              'No Answer',              0, 'condition.no_answer',              1793923200000, 1793923200000),
    (3, 'abnormal',               'Abnormal',               0, 'condition.abnormal',               1793923200000, 1793923200000),
    (4, 'output_abnormal',        'Output Abnormal',        0, 'condition.output_abnormal',        1793923200000, 1793923200000),
    (5, 'bad_answer',             'Bad Answer',             0, 'condition.bad_answer',             1793923200000, 1793923200000),
    (6, 'disabled_device',        'Disabled Device',        0, 'condition.disabled_device',        1793923200000, 1793923200000),
    (7, 'sensor_dirty',           'Sensor Dirty',           0, 'condition.sensor_dirty',           1793923200000, 1793923200000),
    (8, 'open_circuit_reporting', 'Open Circuit Reporting', 0, 'condition.open_circuit_reporting', 1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;
