-- Module 01: tenancy — tenants, sites, spaces, floor plans, placements (M1: D9, D10, D11, P8, P5; M3: D6, G7, G11, P9)

-- ---------------------------------------------------------------------
-- 1. Tenancy, sites and spaces
-- ---------------------------------------------------------------------
-- Tenant: top of the isolation hierarchy (req 54, 55). Master data: soft-deleted via status.
-- Suspending or archiving a tenant removes its users' access ONLY. The service keeps ingesting and
-- recording events from the tenant's sites, and history stays reportable (req 54). The service's scope
-- check reads tenant.status and site.status; ingest never does.
CREATE TABLE tenant (
    id           INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL UNIQUE,
    status       TEXT    NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','archived')),
    archived_at  INTEGER CHECK (archived_at > 0),                -- set exactly when status = 'archived' (req 54)
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK ((status = 'archived') = (archived_at IS NOT NULL))
) STRICT;

-- Site (req 54, 59). timezone is an IANA zone name, required, validated by the service (no default).
-- status follows the tenant rule: 'suspended' / 'archived' remove user access to the site only;
-- ingest and recording from its gateways continue, and its history stays reportable (req 54).
-- Effective access = tenant.status = 'active' AND site.status = 'active'.
CREATE TABLE site (
    id           INTEGER PRIMARY KEY,
    tenant_id    INTEGER NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
    name         TEXT    NOT NULL,
    timezone     TEXT    NOT NULL,
    status       TEXT    NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','archived')),
    archived_at  INTEGER CHECK (archived_at > 0),                -- set exactly when status = 'archived' (req 54)
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (tenant_id, name),
    CHECK ((status = 'archived') = (archived_at IS NOT NULL))
) STRICT;

-- Allowed parent/child space types (req 30, D6, ADR-010). parent_type NULL = allowed at the root of a site.
-- Seeded by db/seed/04_space.sql. The type list matches space.type.
CREATE TABLE space_type_rule (
    id           INTEGER PRIMARY KEY,
    parent_type  TEXT    CHECK (parent_type IN ('building','floor','zone','room','other')),
    child_type   TEXT    NOT NULL CHECK (child_type IN ('building','floor','zone','room','other')),
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;
CREATE UNIQUE INDEX ux_space_type_rule_pair ON space_type_rule(IFNULL(parent_type, ''), child_type);

-- Building > floor > zone > room (at least three levels per site, req 30; up to 8, ADR-010).
-- Hierarchy rules (D6) are enforced by the trg_space_* triggers below: the parent is in the same site,
-- no cycles, the type pair is in space_type_rule, site_id never changes. depth is maintained by
-- trigger (0 = root) and may not be written directly.
CREATE TABLE space (
    id           INTEGER PRIMARY KEY,
    site_id      INTEGER NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
    parent_space_id INTEGER REFERENCES space(id) ON DELETE RESTRICT,  -- was parent_id (ADR-000 item 7)
    type         TEXT    NOT NULL CHECK (type IN ('building','floor','zone','room','other')),
    name         TEXT    NOT NULL,          -- display name as typed (EN or AR); search keys: ADR-013 (P9, M4)
    sort_order   INTEGER NOT NULL DEFAULT 0,
    depth        INTEGER NOT NULL DEFAULT 0 CHECK (depth BETWEEN 0 AND 7),  -- levels below the root; trigger-maintained (req 30)
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;
CREATE INDEX ix_space_site_parent ON space(site_id, parent_space_id);
CREATE INDEX ix_space_parent_space_id ON space(parent_space_id) WHERE parent_space_id IS NOT NULL;

-- Ancestor/descendant pairs of space, including each space with itself at depth 0 (req 59, ADR-011).
-- "Role applies to this space and everything beneath it" (user_role.space_id) is one indexed join:
--   user_role.space_id = space_closure.ancestor_space_id AND space_closure.descendant_space_id = :space
-- Derived data: written only by the trg_space_closure_* triggers on space; the service never writes it.
CREATE TABLE space_closure (
    ancestor_space_id   INTEGER NOT NULL REFERENCES space(id) ON DELETE CASCADE,
    descendant_space_id INTEGER NOT NULL REFERENCES space(id) ON DELETE CASCADE,
    depth               INTEGER NOT NULL CHECK (depth BETWEEN 0 AND 7),  -- levels between ancestor and descendant
    PRIMARY KEY (ancestor_space_id, descendant_space_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX ix_space_closure_descendant_space_id ON space_closure(descendant_space_id, depth);

-- Insert rules (D6, req 30)
CREATE TRIGGER trg_space_hierarchy_ins BEFORE INSERT ON space
BEGIN
    SELECT RAISE(ABORT, 'space: a space cannot be its own parent')
     WHERE NEW.parent_space_id = NEW.id;
    SELECT RAISE(ABORT, 'space: parent must be in the same site')
     WHERE NEW.parent_space_id IS NOT NULL
       AND (SELECT site_id FROM space WHERE id = NEW.parent_space_id) IS NOT NEW.site_id;
    SELECT RAISE(ABORT, 'space: type not allowed under this parent type')
     WHERE NOT EXISTS (SELECT 1 FROM space_type_rule r
                        WHERE r.child_type = NEW.type
                          AND r.parent_type IS (SELECT type FROM space WHERE id = NEW.parent_space_id));
    SELECT RAISE(ABORT, 'space: maximum depth is 8 levels')
     WHERE (SELECT depth FROM space WHERE id = NEW.parent_space_id) >= 7;
END;

-- Re-parenting and type changes (D6, req 30). The cycle check walks up from the new parent with a
-- recursive CTE; it terminates because the existing tree has no cycle.
CREATE TRIGGER trg_space_hierarchy_upd BEFORE UPDATE OF parent_space_id, type ON space
BEGIN
    SELECT RAISE(ABORT, 'space: parent must be in the same site')
     WHERE NEW.parent_space_id IS NOT NULL
       AND (SELECT site_id FROM space WHERE id = NEW.parent_space_id) IS NOT NEW.site_id;
    SELECT RAISE(ABORT, 'space: cycle (new parent is the space itself or one of its descendants)')
     WHERE NEW.parent_space_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE up(id) AS (
            SELECT NEW.parent_space_id
            UNION ALL
            SELECT s.parent_space_id FROM space s JOIN up ON s.id = up.id WHERE s.parent_space_id IS NOT NULL)
        SELECT 1 FROM up WHERE up.id = NEW.id);
    SELECT RAISE(ABORT, 'space: type not allowed under this parent type')
     WHERE NOT EXISTS (SELECT 1 FROM space_type_rule r
                        WHERE r.child_type = NEW.type
                          AND r.parent_type IS (SELECT type FROM space WHERE id = NEW.parent_space_id));
    SELECT RAISE(ABORT, 'space: an existing child type is not allowed under the new type')
     WHERE NEW.type IS NOT OLD.type AND EXISTS (
        SELECT 1 FROM space c
         WHERE c.parent_space_id = NEW.id
           AND NOT EXISTS (SELECT 1 FROM space_type_rule r WHERE r.parent_type = NEW.type AND r.child_type = c.type));
    -- new depth of the moved space + height of its subtree must stay within 0..7
    SELECT RAISE(ABORT, 'space: maximum depth is 8 levels')
     WHERE NEW.parent_space_id IS NOT OLD.parent_space_id
       AND IFNULL((SELECT depth + 1 FROM space WHERE id = NEW.parent_space_id), 0)
           + (SELECT max(depth) FROM space_closure WHERE ancestor_space_id = NEW.id) > 7;
END;

CREATE TRIGGER trg_space_site_immutable BEFORE UPDATE OF site_id ON space
WHEN NEW.site_id IS NOT OLD.site_id
BEGIN SELECT RAISE(ABORT, 'space: site_id cannot change'); END;

-- depth is derived: it must equal the distance to the root recorded in space_closure.
CREATE TRIGGER trg_space_depth_derived BEFORE UPDATE OF depth ON space
WHEN NEW.depth IS NOT (SELECT max(depth) FROM space_closure WHERE descendant_space_id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'space: depth is trigger-maintained'); END;

-- Closure + depth maintenance (ADR-011). Insert: self row, then one row per ancestor of the parent.
CREATE TRIGGER trg_space_closure_ins AFTER INSERT ON space
BEGIN
    INSERT INTO space_closure (ancestor_space_id, descendant_space_id, depth)
    SELECT NEW.id, NEW.id, 0
    UNION ALL
    SELECT c.ancestor_space_id, NEW.id, c.depth + 1
      FROM space_closure c WHERE c.descendant_space_id = NEW.parent_space_id;
    UPDATE space SET depth = (SELECT max(depth) FROM space_closure WHERE descendant_space_id = NEW.id)
     WHERE id = NEW.id;
END;

-- Move: unlink the subtree from its old ancestors, link it under the new ancestors, re-derive depth.
CREATE TRIGGER trg_space_closure_move AFTER UPDATE OF parent_space_id ON space
WHEN NEW.parent_space_id IS NOT OLD.parent_space_id
BEGIN
    DELETE FROM space_closure
     WHERE descendant_space_id IN (SELECT descendant_space_id FROM space_closure WHERE ancestor_space_id = NEW.id)
       AND ancestor_space_id   IN (SELECT ancestor_space_id FROM space_closure
                                    WHERE descendant_space_id = NEW.id AND ancestor_space_id <> NEW.id);
    INSERT INTO space_closure (ancestor_space_id, descendant_space_id, depth)
    SELECT a.ancestor_space_id, d.descendant_space_id, a.depth + d.depth + 1
      FROM space_closure a, space_closure d
     WHERE a.descendant_space_id = NEW.parent_space_id
       AND d.ancestor_space_id = NEW.id;
    UPDATE space SET depth = (SELECT max(depth) FROM space_closure WHERE descendant_space_id = space.id)
     WHERE id IN (SELECT descendant_space_id FROM space_closure WHERE ancestor_space_id = NEW.id);
END;

-- ---------------------------------------------------------------------
-- 2. Floor plans and placements
-- ---------------------------------------------------------------------
-- Floor plan image revision (req 29, 39, G7, ADR-012). width_px / height_px / size_bytes / sha256 are read
-- from the file by the service on upload. A space has at most one current and one draft revision.
-- Replacement is draft-first: the draft gets copies of the current placements as needs_review, every
-- placement is confirmed, then the current revision is superseded and the draft promoted in one
-- transaction; a rejected draft leaves the current revision untouched (docs/db/PLAN_REPLACEMENT.md).
-- Revisions are never deleted. Content columns are immutable.
CREATE TABLE floor_plan (
    id           INTEGER PRIMARY KEY,
    space_id     INTEGER NOT NULL REFERENCES space(id) ON DELETE RESTRICT,
    revision_no  INTEGER NOT NULL CHECK (revision_no >= 1),  -- 1, 2, 3 … per space, assigned max + 1
    replaces_floor_plan_id INTEGER REFERENCES floor_plan(id) ON DELETE RESTRICT,  -- the current plan when this revision was uploaded
    status       TEXT    NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','current','superseded','rejected')),  -- closed state machine, trg_floor_plan_status
    status_changed_at INTEGER CHECK (status_changed_at > 0),
    file_name    TEXT    NOT NULL,
    mime_type    TEXT    NOT NULL CHECK (mime_type IN ('image/png','image/jpeg','image/webp','image/svg+xml')),
    width_px     INTEGER NOT NULL CHECK (width_px  BETWEEN 1 AND 8192),
    height_px    INTEGER NOT NULL CHECK (height_px BETWEEN 1 AND 8192),
    size_bytes   INTEGER NOT NULL CHECK (size_bytes <= 20971520),   -- 20 MB
    sha256       TEXT    NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),  -- dedupe per space over live revisions
    storage_path TEXT    NOT NULL,          -- file kept on disk, not in the database
    is_current   INTEGER NOT NULL GENERATED ALWAYS AS (status = 'current') VIRTUAL,  -- kept from Draft v2 for readers; always 0/1, derived from status (ADR-012)
    uploaded_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    uploaded_at  INTEGER NOT NULL CHECK (uploaded_at > 0),
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;
CREATE INDEX ix_floor_plan_space_id ON floor_plan(space_id);
CREATE UNIQUE INDEX ux_floor_plan_space_id_revision_no ON floor_plan(space_id, revision_no);
CREATE UNIQUE INDEX ux_floor_plan_current ON floor_plan(space_id) WHERE status = 'current';
CREATE UNIQUE INDEX ux_floor_plan_draft   ON floor_plan(space_id) WHERE status = 'draft';
CREATE UNIQUE INDEX ux_floor_plan_space_id_sha256 ON floor_plan(space_id, sha256) WHERE status IN ('draft','current');
CREATE INDEX ix_floor_plan_replaces_floor_plan_id ON floor_plan(replaces_floor_plan_id) WHERE replaces_floor_plan_id IS NOT NULL;

CREATE TRIGGER trg_floor_plan_revision_ins BEFORE INSERT ON floor_plan
BEGIN
    -- values outside the CHECK domains are left to the CHECKs (status list, revision_no >= 1)
    SELECT RAISE(ABORT, 'floor_plan: a new revision must be draft or current')
     WHERE NEW.status IN ('superseded','rejected');
    SELECT RAISE(ABORT, 'floor_plan: revision_no must be the next number for the space')
     WHERE NEW.revision_no >= 1 AND NEW.revision_no IS NOT IFNULL((SELECT max(revision_no) FROM floor_plan WHERE space_id = NEW.space_id), 0) + 1;
    SELECT RAISE(ABORT, 'floor_plan: a space has one current plan; replace it through a draft')
     WHERE NEW.status = 'current'
       AND EXISTS (SELECT 1 FROM floor_plan WHERE space_id = NEW.space_id AND status = 'current');
    SELECT RAISE(ABORT, 'floor_plan: replaces_floor_plan_id must be the current plan of the space')
     WHERE NEW.replaces_floor_plan_id IS NOT (SELECT id FROM floor_plan WHERE space_id = NEW.space_id AND status = 'current');
END;

-- Allowed transitions: draft -> current | rejected, current -> superseded. superseded / rejected are final.
CREATE TRIGGER trg_floor_plan_status BEFORE UPDATE OF status ON floor_plan
WHEN NEW.status IS NOT OLD.status
BEGIN
    SELECT RAISE(ABORT, 'floor_plan: status transition not allowed')
     WHERE NOT ((OLD.status = 'draft' AND NEW.status IN ('current','rejected'))
             OR (OLD.status = 'current' AND NEW.status = 'superseded'));
    SELECT RAISE(ABORT, 'floor_plan: only a plan with a pending draft replacing it can be superseded')
     WHERE NEW.status = 'superseded'
       AND NOT EXISTS (SELECT 1 FROM floor_plan d WHERE d.replaces_floor_plan_id = OLD.id AND d.status = 'draft');
    SELECT RAISE(ABORT, 'floor_plan: supersede the replaced plan before promoting the draft')
     WHERE NEW.status = 'current' AND OLD.replaces_floor_plan_id IS NOT NULL
       AND (SELECT status FROM floor_plan WHERE id = OLD.replaces_floor_plan_id) <> 'superseded';
    SELECT RAISE(ABORT, 'floor_plan: placements still need review')
     WHERE NEW.status = 'current'
       AND EXISTS (SELECT 1 FROM plan_placement WHERE floor_plan_id = OLD.id AND status = 'needs_review');
END;

CREATE TRIGGER trg_floor_plan_content_immutable
BEFORE UPDATE OF space_id, revision_no, replaces_floor_plan_id, file_name, mime_type, width_px, height_px,
                 size_bytes, sha256, storage_path, uploaded_by_user_account_id, uploaded_at ON floor_plan
WHEN NEW.space_id IS NOT OLD.space_id OR NEW.revision_no IS NOT OLD.revision_no
  OR NEW.replaces_floor_plan_id IS NOT OLD.replaces_floor_plan_id OR NEW.file_name IS NOT OLD.file_name
  OR NEW.mime_type IS NOT OLD.mime_type OR NEW.width_px IS NOT OLD.width_px OR NEW.height_px IS NOT OLD.height_px
  OR NEW.size_bytes IS NOT OLD.size_bytes OR NEW.sha256 IS NOT OLD.sha256 OR NEW.storage_path IS NOT OLD.storage_path
  OR NEW.uploaded_by_user_account_id IS NOT OLD.uploaded_by_user_account_id OR NEW.uploaded_at IS NOT OLD.uploaded_at
BEGIN SELECT RAISE(ABORT, 'floor_plan: revision content is immutable; upload a new revision'); END;

-- Where a device, controller or gateway is drawn on a floor plan revision (requirements 31, 34, 39).
-- Separate from device.space_id so a plan can be replaced and placements re-confirmed,
-- and so one item can appear on more than one plan (e.g. floor plan and riser overview).
-- floor_plan_id is RESTRICT (was CASCADE in Draft v2): placements must survive for plan rollback (G7, ADR-001).
-- Placements belong to one revision (ADR-012): they are frozen once the revision is superseded or rejected,
-- and the target must be in the plan's site (D6).
CREATE TABLE plan_placement (
    id               INTEGER PRIMARY KEY,
    floor_plan_id    INTEGER NOT NULL REFERENCES floor_plan(id) ON DELETE RESTRICT,
    device_id        INTEGER REFERENCES device(id) ON DELETE RESTRICT,
    controller_id    INTEGER REFERENCES controller(id) ON DELETE RESTRICT,
    gateway_id       INTEGER REFERENCES gateway(id) ON DELETE RESTRICT,
    x                REAL    NOT NULL CHECK (x BETWEEN 0 AND 1),   -- relative to plan width
    y                REAL    NOT NULL CHECK (y BETWEEN 0 AND 1),   -- relative to plan height
    rotation_deg     REAL    NOT NULL DEFAULT 0 CHECK (rotation_deg >= 0 AND rotation_deg < 360),
    symbol           TEXT,                             -- icon override; default comes from device type
    status           TEXT    NOT NULL DEFAULT 'placed'
                     CHECK (status IN ('placed','needs_review')),  -- needs_review only on a draft revision (req 39)
    placed_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    placed_at        INTEGER NOT NULL CHECK (placed_at > 0),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK ((device_id IS NOT NULL) + (controller_id IS NOT NULL) + (gateway_id IS NOT NULL) = 1)
) STRICT;
CREATE UNIQUE INDEX ux_plan_placement_device     ON plan_placement(floor_plan_id, device_id)     WHERE device_id     IS NOT NULL;
CREATE UNIQUE INDEX ux_plan_placement_controller ON plan_placement(floor_plan_id, controller_id) WHERE controller_id IS NOT NULL;
CREATE UNIQUE INDEX ux_plan_placement_gateway    ON plan_placement(floor_plan_id, gateway_id)    WHERE gateway_id    IS NOT NULL;
CREATE INDEX ix_plan_placement_floor_plan_id ON plan_placement(floor_plan_id);
CREATE INDEX ix_plan_placement_device_id     ON plan_placement(device_id);
CREATE INDEX ix_plan_placement_controller_id ON plan_placement(controller_id) WHERE controller_id IS NOT NULL;
CREATE INDEX ix_plan_placement_gateway_id    ON plan_placement(gateway_id)    WHERE gateway_id    IS NOT NULL;

-- Insert rules: revision not frozen, needs_review only on a draft, target in the plan's site (D6).
-- Target site: gateway.site_id; controller -> gateway; device -> controller -> gateway.
CREATE TRIGGER trg_plan_placement_ins BEFORE INSERT ON plan_placement
BEGIN
    SELECT RAISE(ABORT, 'plan_placement: plan revision is frozen')
     WHERE (SELECT status FROM floor_plan WHERE id = NEW.floor_plan_id) IN ('superseded','rejected');
    SELECT RAISE(ABORT, 'plan_placement: needs_review only on a draft revision')
     WHERE NEW.status = 'needs_review' AND (SELECT status FROM floor_plan WHERE id = NEW.floor_plan_id) <> 'draft';
    SELECT RAISE(ABORT, 'plan_placement: target not in plan''s site')
     WHERE (SELECT s.site_id FROM floor_plan fp JOIN space s ON s.id = fp.space_id WHERE fp.id = NEW.floor_plan_id)
       IS NOT (CASE
                WHEN NEW.device_id IS NOT NULL THEN
                    (SELECT g.site_id FROM device d JOIN controller c ON c.id = d.controller_id
                                                    JOIN gateway g ON g.id = c.gateway_id WHERE d.id = NEW.device_id)
                WHEN NEW.controller_id IS NOT NULL THEN
                    (SELECT g.site_id FROM controller c JOIN gateway g ON g.id = c.gateway_id WHERE c.id = NEW.controller_id)
                ELSE (SELECT site_id FROM gateway WHERE id = NEW.gateway_id)
               END);
END;

CREATE TRIGGER trg_plan_placement_upd BEFORE UPDATE ON plan_placement
BEGIN
    SELECT RAISE(ABORT, 'plan_placement: plan revision is frozen')
     WHERE (SELECT status FROM floor_plan WHERE id = OLD.floor_plan_id) IN ('superseded','rejected');
    SELECT RAISE(ABORT, 'plan_placement: a placement cannot move to another plan revision')
     WHERE NEW.floor_plan_id IS NOT OLD.floor_plan_id;
    SELECT RAISE(ABORT, 'plan_placement: needs_review only on a draft revision')
     WHERE NEW.status = 'needs_review' AND (SELECT status FROM floor_plan WHERE id = NEW.floor_plan_id) <> 'draft';
    SELECT RAISE(ABORT, 'plan_placement: target not in plan''s site')
     WHERE (NEW.device_id IS NOT OLD.device_id OR NEW.controller_id IS NOT OLD.controller_id OR NEW.gateway_id IS NOT OLD.gateway_id)
       AND (SELECT s.site_id FROM floor_plan fp JOIN space s ON s.id = fp.space_id WHERE fp.id = NEW.floor_plan_id)
       IS NOT (CASE
                WHEN NEW.device_id IS NOT NULL THEN
                    (SELECT g.site_id FROM device d JOIN controller c ON c.id = d.controller_id
                                                    JOIN gateway g ON g.id = c.gateway_id WHERE d.id = NEW.device_id)
                WHEN NEW.controller_id IS NOT NULL THEN
                    (SELECT g.site_id FROM controller c JOIN gateway g ON g.id = c.gateway_id WHERE c.id = NEW.controller_id)
                ELSE (SELECT site_id FROM gateway WHERE id = NEW.gateway_id)
               END);
END;

CREATE TRIGGER trg_plan_placement_del BEFORE DELETE ON plan_placement
WHEN (SELECT status FROM floor_plan WHERE id = OLD.floor_plan_id) IN ('superseded','rejected')
BEGIN SELECT RAISE(ABORT, 'plan_placement: plan revision is frozen'); END;

-- Mapping completeness (req 35), STUB until M10: per space, devices whose logical space is the space or
-- beneath it, and how many of them are placed on a current plan revision. Query with WHERE space_id = ?.
CREATE VIEW v_space_mapping_completeness AS
SELECT s.id      AS space_id,
       s.site_id AS site_id,
       count(d.id) AS device_count,
       IFNULL(sum(EXISTS (SELECT 1 FROM plan_placement pp JOIN floor_plan fp ON fp.id = pp.floor_plan_id
                           WHERE pp.device_id = d.id AND pp.status = 'placed' AND fp.status = 'current')), 0) AS mapped_count
  FROM space s
  JOIN space_closure sc ON sc.ancestor_space_id = s.id
  LEFT JOIN device d ON d.space_id = sc.descendant_space_id
 GROUP BY s.id, s.site_id;
