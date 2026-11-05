-- Module 07: audit — tamper-evident append-only audit log (M1: P4, D9, D10, D11)

-- ---------------------------------------------------------------------
-- 6. Audit log (append-only, tamper-evident; requirement 50). Ids leave the DB: AUTOINCREMENT.
--    All FKs RESTRICT: a user or session in the audit trail can never be deleted (ADR-001).
--    FK indexes deferred to M9 (ADR-002).
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    at               INTEGER NOT NULL CHECK (at > 0),
    user_id          INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,  -- renamed user_account_id in M9
    session_id       INTEGER REFERENCES session(id) ON DELETE RESTRICT,
    client_host      TEXT,
    action           TEXT    NOT NULL,                 -- e.g. auth.login, auth.pin_fail, panel.silence, settings.change
    target_type      TEXT,
    target_id        TEXT,
    outcome          TEXT    NOT NULL CHECK (outcome IN ('success','refused','failed')),
    before_json      TEXT                              -- non-secret previous values
                     CHECK (before_json IS NULL OR (json_valid(before_json) AND json_type(before_json) = 'object')),
    after_json       TEXT
                     CHECK (after_json IS NULL OR (json_valid(after_json) AND json_type(after_json) = 'object')),
    detail           TEXT,
    prev_hash        TEXT    NOT NULL                  -- row_hash of the previous row (64 zeros for the first row)
                     CHECK (length(prev_hash) = 64 AND prev_hash NOT GLOB '*[^0-9a-f]*'),
    row_hash         TEXT    NOT NULL                  -- SHA-256 over this row's fields + prev_hash
                     CHECK (length(row_hash) = 64 AND row_hash NOT GLOB '*[^0-9a-f]*')
) STRICT;
CREATE INDEX ix_audit_log_at ON audit_log(at);

-- No update or delete at any permission level
CREATE TRIGGER trg_audit_log_no_update BEFORE UPDATE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
CREATE TRIGGER trg_audit_log_no_delete BEFORE DELETE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
