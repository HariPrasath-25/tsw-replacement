-- Module 06: identity — users, roles, permissions, scope, sessions (M1: D9, D10, D11, P8, P5)

-- ---------------------------------------------------------------------
-- 5. Users, roles, permissions, scope and sessions
-- ---------------------------------------------------------------------
-- Local and Windows accounts (req 56, 60-66). Master data: disabled via status, never hard-deleted.
CREATE TABLE user_account (
    id               INTEGER PRIMARY KEY,
    username         TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    display_name     TEXT    NOT NULL,
    auth_type        TEXT    NOT NULL CHECK (auth_type IN ('windows','local')),
    windows_sid      TEXT    UNIQUE,                   -- for Windows/AD sign-on
    password_hash    TEXT,                             -- Argon2id PHC string (local accounts); not SHA-256 (ADR-000)
    pin_hash         TEXT,                             -- Argon2id PHC string; set at first sign-in
    is_fallback      INTEGER NOT NULL DEFAULT 0 CHECK (is_fallback IN (0,1)),  -- requirement 61
    status           TEXT    NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    failed_attempts  INTEGER NOT NULL DEFAULT 0,
    locked_until     INTEGER CHECK (locked_until > 0),
    ui_prefs_json    TEXT    NOT NULL DEFAULT '{}'     -- theme, language
                     CHECK (json_valid(ui_prefs_json) AND json_type(ui_prefs_json) = 'object'),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK (auth_type = 'windows' OR password_hash IS NOT NULL)
) STRICT;

-- Roles (req 56, 57).
CREATE TABLE role (
    id               INTEGER PRIMARY KEY,
    name             TEXT    NOT NULL UNIQUE,          -- Viewer, Operator, Engineer, Administrator
    is_builtin       INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0,1)),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;

-- Permissions (req 57).
CREATE TABLE permission (
    id               INTEGER PRIMARY KEY,
    code             TEXT    NOT NULL UNIQUE,          -- e.g. alarm.ack, panel.silence, panel.reset,View Floor Plan
    description      TEXT    NOT NULL,
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;

-- Role -> permission link. Pure child of role: CASCADE; a permission in use cannot be deleted.
CREATE TABLE role_permission (
    id               INTEGER PRIMARY KEY,
    role_id          INTEGER NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    permission_id    INTEGER NOT NULL REFERENCES permission(id) ON DELETE RESTRICT,
    UNIQUE (role_id, permission_id)
) STRICT;
CREATE INDEX ix_role_permission_permission_id ON role_permission(permission_id);

-- Role assignments with their scope (requirements 56, 59): a user holds a role
-- for a whole tenant, one site, or one space and everything beneath it.
--   tenant only            -> role applies across the tenant
--   tenant + site          -> role applies to that site
--   tenant + site + space  -> role applies to that space and its child spaces
--                             (e.g. Operator for Floor 16, or for office unit 16-02)
-- A user may hold several assignments (e.g. Viewer for the site, Operator for Floor 16).
-- user_id is RESTRICT (was CASCADE in Draft v2): users are disabled, not deleted (ADR-001).
CREATE TABLE user_role (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id) ON DELETE RESTRICT,  -- renamed user_account_id in M7
    role_id          INTEGER NOT NULL REFERENCES role(id) ON DELETE RESTRICT,
    tenant_id        INTEGER NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
    site_id          INTEGER REFERENCES site(id) ON DELETE RESTRICT,
    space_id         INTEGER REFERENCES space(id) ON DELETE RESTRICT,
    granted_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    granted_at       INTEGER NOT NULL CHECK (granted_at > 0),
    CHECK (space_id IS NULL OR site_id IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX ux_user_role_scope
    ON user_role(user_id, role_id, tenant_id, IFNULL(site_id, 0), IFNULL(space_id, 0));
CREATE INDEX ix_user_role_role_id   ON user_role(role_id);
CREATE INDEX ix_user_role_tenant_id ON user_role(tenant_id);
CREATE INDEX ix_user_role_site_id   ON user_role(site_id)  WHERE site_id  IS NOT NULL;
CREATE INDEX ix_user_role_space_id  ON user_role(space_id) WHERE space_id IS NOT NULL;

-- AD group to role mapping (requirement 66), with the same optional scope
CREATE TABLE directory_group_role (
    id               INTEGER PRIMARY KEY,
    group_sid        TEXT    NOT NULL,
    role_id          INTEGER NOT NULL REFERENCES role(id) ON DELETE RESTRICT,
    tenant_id        INTEGER NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
    site_id          INTEGER REFERENCES site(id) ON DELETE RESTRICT,
    space_id         INTEGER REFERENCES space(id) ON DELETE RESTRICT,
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK (space_id IS NULL OR site_id IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX ux_directory_group_role_scope
    ON directory_group_role(group_sid, role_id, tenant_id, IFNULL(site_id, 0), IFNULL(space_id, 0));
CREATE INDEX ix_directory_group_role_role_id   ON directory_group_role(role_id);
CREATE INDEX ix_directory_group_role_tenant_id ON directory_group_role(tenant_id);
CREATE INDEX ix_directory_group_role_site_id   ON directory_group_role(site_id)  WHERE site_id  IS NOT NULL;
CREATE INDEX ix_directory_group_role_space_id  ON directory_group_role(space_id) WHERE space_id IS NOT NULL;

-- Keep scopes consistent: the site must belong to the tenant, and the space to the site
CREATE TRIGGER trg_user_role_scope BEFORE INSERT ON user_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'user_role scope: site/space does not belong to the tenant/site'); END;
CREATE TRIGGER trg_user_role_scope_upd BEFORE UPDATE ON user_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'user_role scope: site/space does not belong to the tenant/site'); END;
CREATE TRIGGER trg_directory_group_role_scope BEFORE INSERT ON directory_group_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'directory_group_role scope: site/space does not belong to the tenant/site'); END;

-- Client sessions (req 60, 62, 64). token_hash is SHA-256 hex of the random token; the token is never stored.
-- Kept while audit_log/command reference them (RESTRICT, ADR-001).
CREATE TABLE session (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id) ON DELETE RESTRICT,  -- renamed user_account_id in M7
    token_hash       TEXT    NOT NULL UNIQUE
                     CHECK (length(token_hash) = 64 AND token_hash NOT GLOB '*[^0-9a-f]*'),
    client_kind      TEXT    NOT NULL CHECK (client_kind IN ('desktop','web')),
    client_host      TEXT,
    started_at       INTEGER NOT NULL CHECK (started_at > 0),
    last_activity    INTEGER NOT NULL CHECK (last_activity > 0),
    is_locked        INTEGER NOT NULL DEFAULT 0 CHECK (is_locked IN (0,1)),
    ended_at         INTEGER CHECK (ended_at > 0),
    end_reason       TEXT    CHECK (end_reason IN ('logout','expired','pin_failures','admin','service_restart')),
    CHECK ((ended_at IS NULL) = (end_reason IS NULL))
) STRICT;
CREATE INDEX ix_session_open ON session(user_id) WHERE ended_at IS NULL;
CREATE INDEX ix_session_user_id ON session(user_id, started_at);
