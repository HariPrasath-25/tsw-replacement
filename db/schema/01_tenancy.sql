-- Module 01: tenancy — tenants, sites, spaces, floor plans, placements (M1: D9, D10, D11, P8, P5)

-- ---------------------------------------------------------------------
-- 1. Tenancy, sites and spaces
-- ---------------------------------------------------------------------
-- Tenant: top of the isolation hierarchy (req 54, 55). Master data: soft-deleted via status.
CREATE TABLE tenant (
    id           INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL UNIQUE,
    status       TEXT    NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','archived')),
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;

-- Site (req 54). timezone is an IANA zone name, required, validated by the service (no default).
CREATE TABLE site (
    id           INTEGER PRIMARY KEY,
    tenant_id    INTEGER NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
    name         TEXT    NOT NULL,
    timezone     TEXT    NOT NULL,
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (tenant_id, name)
) STRICT;

-- Building > floor > zone (at least three levels, requirement 30)
CREATE TABLE space (
    id           INTEGER PRIMARY KEY,
    site_id      INTEGER NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
    parent_id    INTEGER REFERENCES space(id) ON DELETE RESTRICT,   -- renamed parent_space_id in M3 (ADR-000 item 7)
    type         TEXT    NOT NULL CHECK (type IN ('building','floor','zone','room','other')),
    name         TEXT    NOT NULL,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;
CREATE INDEX ix_space_site_parent ON space(site_id, parent_id);
CREATE INDEX ix_space_parent_id ON space(parent_id) WHERE parent_id IS NOT NULL;

-- Floor plan image metadata (req 31, 39). width_px / height_px / size_bytes / sha256 are read from the
-- file by the service on upload. Plans are retired (is_current = 0), never deleted.
CREATE TABLE floor_plan (
    id           INTEGER PRIMARY KEY,
    space_id     INTEGER NOT NULL REFERENCES space(id) ON DELETE RESTRICT,
    file_name    TEXT    NOT NULL,
    mime_type    TEXT    NOT NULL CHECK (mime_type IN ('image/png','image/jpeg','image/webp','image/svg+xml')),
    width_px     INTEGER NOT NULL CHECK (width_px  BETWEEN 1 AND 8192),
    height_px    INTEGER NOT NULL CHECK (height_px BETWEEN 1 AND 8192),
    size_bytes   INTEGER NOT NULL CHECK (size_bytes <= 20971520),   -- 20 MB
    sha256       TEXT    NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    storage_path TEXT    NOT NULL,          -- file kept on disk, not in the database
    is_current   INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0,1)),
    uploaded_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    uploaded_at  INTEGER NOT NULL CHECK (uploaded_at > 0),
    created_at   INTEGER NOT NULL CHECK (created_at > 0),
    updated_at   INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version  INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;
CREATE INDEX ix_floor_plan_space_id ON floor_plan(space_id);

-- Where a device, controller or gateway is drawn on a floor plan (requirements 31, 34, 39).
-- Separate from device.space_id so a plan can be replaced and placements re-confirmed,
-- and so one item can appear on more than one plan (e.g. floor plan and riser overview).
-- floor_plan_id is RESTRICT (was CASCADE in Draft v2): placements must survive for plan rollback (G7, ADR-001).
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
                     CHECK (status IN ('placed','needs_review')),  -- needs_review after a plan is replaced
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
