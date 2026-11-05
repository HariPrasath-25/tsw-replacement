-- Module 08: integrity — quarantine and gateway health (M1: D9, D10, D11, P5)

-- ---------------------------------------------------------------------
-- 7. Integrity: quarantine and gateway health
-- ---------------------------------------------------------------------
-- Messages that failed validation; never silently discarded (requirement 95).
-- gateway_id is optional by design (sender may be unknown) but, when set, the link is history: RESTRICT.
CREATE TABLE quarantine (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER REFERENCES gateway(id) ON DELETE RESTRICT,
    topic            TEXT    NOT NULL,
    payload          BLOB    NOT NULL,
    error            TEXT    NOT NULL,
    rcv_time         INTEGER NOT NULL CHECK (rcv_time > 0),
    reviewed_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    reviewed_at      INTEGER CHECK (reviewed_at > 0)
) STRICT;
CREATE INDEX ix_quarantine_gateway_id ON quarantine(gateway_id) WHERE gateway_id IS NOT NULL;

-- Gateway health samples (req 22, 24). History: RESTRICT.
CREATE TABLE gateway_health (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id) ON DELETE RESTRICT,
    rcv_time         INTEGER NOT NULL CHECK (rcv_time > 0),
    cpu_pct          REAL,
    mem_pct          REAL,
    disk_pct         REAL,
    buffer_depth     INTEGER,
    detail_json      TEXT
                     CHECK (detail_json IS NULL OR (json_valid(detail_json) AND json_type(detail_json) = 'object'))
) STRICT;
CREATE INDEX ix_gateway_health_gateway_id_rcv_time ON gateway_health(gateway_id, rcv_time);
