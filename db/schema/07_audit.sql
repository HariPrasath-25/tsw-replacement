-- Module 07: audit (split verbatim from Draft v2 in M0; source of truth from here on)

-- ---------------------------------------------------------------------
-- 6. Audit log (append-only, tamper-evident; requirement 50)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY,
    at               INTEGER NOT NULL,
    user_id          INTEGER REFERENCES user_account(id),
    session_id       INTEGER REFERENCES session(id),
    client_host      TEXT,
    action           TEXT    NOT NULL,                 -- e.g. auth.login, auth.pin_fail, panel.silence, settings.change
    target_type      TEXT,
    target_id        TEXT,
    outcome          TEXT    NOT NULL CHECK (outcome IN ('success','refused','failed')),
    before_json      TEXT,                             -- non-secret previous values
    after_json       TEXT,
    detail           TEXT,
    prev_hash        TEXT    NOT NULL,                 -- row_hash of the previous row
    row_hash         TEXT    NOT NULL                  -- SHA-256 over this row's fields + prev_hash
) STRICT;
CREATE INDEX ix_audit_at ON audit_log(at);

-- No update or delete at any permission level
CREATE TRIGGER trg_audit_no_update BEFORE UPDATE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
CREATE TRIGGER trg_audit_no_delete BEFORE DELETE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
