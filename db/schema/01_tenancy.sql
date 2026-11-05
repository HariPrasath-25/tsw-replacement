-- Module 01: tenancy (split verbatim from Draft v2 in M0; source of truth from here on)

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
