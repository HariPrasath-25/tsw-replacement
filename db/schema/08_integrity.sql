-- Module 08: integrity (split verbatim from Draft v2 in M0; source of truth from here on)

-- ---------------------------------------------------------------------
-- 7. Integrity: quarantine and gateway health
-- ---------------------------------------------------------------------
-- Messages that failed validation; never silently discarded (requirement 95)
CREATE TABLE quarantine (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER REFERENCES gateway(id),
    topic            TEXT    NOT NULL,
    payload          BLOB    NOT NULL,
    error            TEXT    NOT NULL,
    rcv_time         INTEGER NOT NULL,
    reviewed_by      INTEGER REFERENCES user_account(id),
    reviewed_at      INTEGER
) STRICT;

CREATE TABLE gateway_health (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id),
    rcv_time         INTEGER NOT NULL,
    cpu_pct          REAL,
    mem_pct          REAL,
    disk_pct         REAL,
    buffer_depth     INTEGER,
    detail_json      TEXT
) STRICT;
CREATE INDEX ix_gwh_gateway_time ON gateway_health(gateway_id, rcv_time);
