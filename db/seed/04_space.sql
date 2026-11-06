-- Seed 04: space — allowed parent/child space types (M3: D6, req 30, ADR-010)
--
-- Idempotent: every INSERT is ON CONFLICT DO NOTHING, so applying this file twice changes nothing.
-- created_at / updated_at = 1793923200000 (2026-11-06T00:00:00Z) so builds are deterministic.
-- parent_type NULL = allowed at the root of a site. Approved in chat 2026-11-06 ("structured" set).

INSERT INTO space_type_rule (id, parent_type, child_type, created_at, updated_at) VALUES
    ( 1, NULL,       'building', 1793923200000, 1793923200000),
    ( 2, NULL,       'other',    1793923200000, 1793923200000),
    ( 3, 'building', 'floor',    1793923200000, 1793923200000),
    ( 4, 'building', 'zone',     1793923200000, 1793923200000),
    ( 5, 'building', 'other',    1793923200000, 1793923200000),
    ( 6, 'floor',    'zone',     1793923200000, 1793923200000),
    ( 7, 'floor',    'room',     1793923200000, 1793923200000),
    ( 8, 'floor',    'other',    1793923200000, 1793923200000),
    ( 9, 'zone',     'zone',     1793923200000, 1793923200000),
    (10, 'zone',     'room',     1793923200000, 1793923200000),
    (11, 'zone',     'other',    1793923200000, 1793923200000),
    (12, 'room',     'other',    1793923200000, 1793923200000),
    (13, 'other',    'building', 1793923200000, 1793923200000),
    (14, 'other',    'floor',    1793923200000, 1793923200000),
    (15, 'other',    'zone',     1793923200000, 1793923200000),
    (16, 'other',    'room',     1793923200000, 1793923200000),
    (17, 'other',    'other',    1793923200000, 1793923200000)
ON CONFLICT DO NOTHING;
