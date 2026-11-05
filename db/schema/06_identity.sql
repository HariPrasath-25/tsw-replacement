-- Module 06: identity (split verbatim from Draft v2 in M0; source of truth from here on)

-- ---------------------------------------------------------------------
-- 5. Users, roles, permissions, scope and sessions
-- ---------------------------------------------------------------------
CREATE TABLE user_account (
    id               INTEGER PRIMARY KEY,
    username         TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    display_name     TEXT    NOT NULL,
    auth_type        TEXT    NOT NULL CHECK (auth_type IN ('windows','local')),
    windows_sid      TEXT    UNIQUE,                   -- for Windows/AD sign-on
    password_hash    TEXT,                             -- Argon2id encoded string (local accounts)
    pin_hash         TEXT,                             -- Argon2id; set at first sign-in
    is_fallback      INTEGER NOT NULL DEFAULT 0 CHECK (is_fallback IN (0,1)),  -- requirement 61
    status           TEXT    NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    failed_attempts  INTEGER NOT NULL DEFAULT 0,
    locked_until     INTEGER,
    ui_prefs_json    TEXT    NOT NULL DEFAULT '{}',    -- theme, language
    created_at       INTEGER NOT NULL,
    CHECK (auth_type = 'windows' OR password_hash IS NOT NULL)
) STRICT;

CREATE TABLE role (
    id               INTEGER PRIMARY KEY,
    name             TEXT    NOT NULL UNIQUE,          -- Viewer, Operator, Engineer, Administrator
    is_builtin       INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0,1))
) STRICT;

CREATE TABLE permission (
    id               INTEGER PRIMARY KEY,
    code             TEXT    NOT NULL UNIQUE,          -- e.g. alarm.ack, panel.silence, panel.reset,View Floor Plan
    description      TEXT    NOT NULL
) STRICT;

CREATE TABLE role_permission (
    id               INTEGER PRIMARY KEY,
    role_id          INTEGER NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    permission_id    INTEGER NOT NULL REFERENCES permission(id),
    UNIQUE (role_id, permission_id)
) STRICT;

-- Role assignments with their scope (requirements 56, 59): a user holds a role
-- for a whole tenant, one site, or one space and everything beneath it.
--   tenant only            -> role applies across the tenant
--   tenant + site          -> role applies to that site
--   tenant + site + space  -> role applies to that space and its child spaces
--                             (e.g. Operator for Floor 16, or for office unit 16-02)
-- A user may hold several assignments (e.g. Viewer for the site, Operator for Floor 16).
CREATE TABLE user_role (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id) ON DELETE CASCADE,
    role_id          INTEGER NOT NULL REFERENCES role(id),
    tenant_id        INTEGER NOT NULL REFERENCES tenant(id),
    site_id          INTEGER REFERENCES site(id),
    space_id         INTEGER REFERENCES space(id),
    granted_by       INTEGER REFERENCES user_account(id),
    granted_at       INTEGER NOT NULL,
    CHECK (space_id IS NULL OR site_id IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX ux_user_role_scope
    ON user_role(user_id, role_id, tenant_id, IFNULL(site_id, 0), IFNULL(space_id, 0));

-- AD group to role mapping (requirement 66), with the same optional scope
CREATE TABLE directory_group_role (
    id               INTEGER PRIMARY KEY,
    group_sid        TEXT    NOT NULL,
    role_id          INTEGER NOT NULL REFERENCES role(id),
    tenant_id        INTEGER NOT NULL REFERENCES tenant(id),
    site_id          INTEGER REFERENCES site(id),
    space_id         INTEGER REFERENCES space(id),
    CHECK (space_id IS NULL OR site_id IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX ux_group_role_scope
    ON directory_group_role(group_sid, role_id, tenant_id, IFNULL(site_id, 0), IFNULL(space_id, 0));

-- Keep scopes consistent: the site must belong to the tenant, and the space to the site
CREATE TRIGGER trg_user_role_scope BEFORE INSERT ON user_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'user_role scope: site/space does not belong to the tenant/site'); END;
CREATE TRIGGER trg_user_role_scope_upd BEFORE UPDATE ON user_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'user_role scope: site/space does not belong to the tenant/site'); END;
CREATE TRIGGER trg_group_role_scope BEFORE INSERT ON directory_group_role
WHEN (NEW.site_id IS NOT NULL AND (SELECT tenant_id FROM site WHERE id = NEW.site_id) <> NEW.tenant_id)
  OR (NEW.space_id IS NOT NULL AND (SELECT site_id FROM space WHERE id = NEW.space_id) <> NEW.site_id)
BEGIN SELECT RAISE(ABORT, 'directory_group_role scope: site/space does not belong to the tenant/site'); END;

CREATE TABLE session (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id),
    token_hash       TEXT    NOT NULL UNIQUE,          -- SHA-256 of the random token; token never stored
    client_kind      TEXT    NOT NULL CHECK (client_kind IN ('desktop','web')),
    client_host      TEXT,
    started_at       INTEGER NOT NULL,
    last_activity    INTEGER NOT NULL,
    locked           INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0,1)),
    ended_at         INTEGER,
    end_reason       TEXT    CHECK (end_reason IN ('logout','expired','pin_failures','admin','service_restart'))
) STRICT;
CREATE INDEX ix_session_open ON session(user_id) WHERE ended_at IS NULL;
