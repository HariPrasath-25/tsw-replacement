-- Module 10: licence (split verbatim from Draft v2 in M0; source of truth from here on)

-- ---------------------------------------------------------------------
-- 9. Licence and acceptance (requirements 70-74)
-- ---------------------------------------------------------------------
CREATE TABLE licence (
    id               INTEGER PRIMARY KEY,
    licence_key_enc  BLOB    NOT NULL,                 -- DPAPI-encrypted
    entitlements_json TEXT   NOT NULL,
    activated_at     INTEGER NOT NULL,
    activation_mode  TEXT    NOT NULL CHECK (activation_mode IN ('online','offline'))
) STRICT;

CREATE TABLE document_acceptance (
    id               INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES user_account(id),
    document         TEXT    NOT NULL CHECK (document IN ('terms','privacy')),
    doc_version      TEXT    NOT NULL,
    accepted_at      INTEGER NOT NULL
) STRICT;
