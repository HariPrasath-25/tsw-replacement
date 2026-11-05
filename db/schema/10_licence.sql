-- Module 10: licence — licence and document acceptance (M1: D9, D10, D11, P5)

-- ---------------------------------------------------------------------
-- 9. Licence and acceptance (requirements 70-74)
-- ---------------------------------------------------------------------
-- Activated licence (req 70, 71). licence_key_enc is DPAPI-encrypted (secret; redact in exports, req 75).
CREATE TABLE licence (
    id               INTEGER PRIMARY KEY,
    licence_key_enc  BLOB    NOT NULL,                 -- DPAPI-encrypted
    entitlements_json TEXT   NOT NULL
                     CHECK (json_valid(entitlements_json) AND json_type(entitlements_json) = 'object'),
    activated_at     INTEGER NOT NULL CHECK (activated_at > 0),
    activation_mode  TEXT    NOT NULL CHECK (activation_mode IN ('online','offline'))
) STRICT;

-- Terms/privacy acceptance per user (req 72, 73). History: RESTRICT.
CREATE TABLE document_acceptance (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id) ON DELETE RESTRICT,  -- renamed user_account_id in M7
    document         TEXT    NOT NULL CHECK (document IN ('terms','privacy')),
    doc_version      TEXT    NOT NULL,
    accepted_at      INTEGER NOT NULL CHECK (accepted_at > 0)
) STRICT;
CREATE INDEX ix_document_acceptance_user_id ON document_acceptance(user_id);
