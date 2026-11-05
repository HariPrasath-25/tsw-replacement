-- Module 02: sources — gateways, controllers, devices and their state (M1: D9, D10, D11, P8, P5)

-- ---------------------------------------------------------------------
-- 2. Sources: gateways, controllers, devices
-- ---------------------------------------------------------------------
-- Logical gateway: its id never changes, so events, controllers and history stay attached
-- when the physical box is swapped. The physical unit (serial) lives in gateway_hardware.
-- Master data (req 22, 26): never hard-deleted.
CREATE TABLE gateway (
    id               INTEGER PRIMARY KEY,
    site_id          INTEGER NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
    space_id         INTEGER REFERENCES space(id) ON DELETE SET NULL,  -- where the gateway is installed, e.g. GF FCC room
    name             TEXT    NOT NULL,
    runtime_version  TEXT,
    contract_version TEXT,
    last_heartbeat   INTEGER CHECK (last_heartbeat > 0),
    conn_state       TEXT    NOT NULL DEFAULT 'unknown'
                     CHECK (conn_state IN ('online','offline','degraded','unknown')),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (site_id, name)
) STRICT;
CREATE INDEX ix_gateway_space_id ON gateway(space_id) WHERE space_id IS NOT NULL;

-- Physical gateway units over time. The service maps an incoming serial to the current row,
-- then to the logical gateway. Replacing a box closes the old row and opens a new one. History.
CREATE TABLE gateway_hardware (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id) ON DELETE RESTRICT,
    serial           TEXT    NOT NULL UNIQUE,          -- e.g. GW1B2511004
    platform         TEXT    NOT NULL DEFAULT 'cm4' CHECK (platform IN ('cm4','ubuntu-vm')),
    installed_at     INTEGER NOT NULL CHECK (installed_at > 0),
    removed_at       INTEGER CHECK (removed_at > 0),   -- NULL = currently installed
    reason           TEXT    NOT NULL DEFAULT 'commissioned'
                     CHECK (reason IN ('commissioned','replaced')),
    changed_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    CHECK (removed_at IS NULL OR removed_at >= installed_at)
) STRICT;
CREATE UNIQUE INDEX ux_gateway_hardware_current ON gateway_hardware(gateway_id) WHERE removed_at IS NULL;
CREATE INDEX ix_gateway_hardware_gateway_id ON gateway_hardware(gateway_id, installed_at);

-- Any controller a gateway talks to: a fire panel (FACP), a BACnet controller, a Modbus meter,
-- an SNMP device... Devices/points hang off a controller. Fire is the only system in release 1.
CREATE TABLE controller (
    id               INTEGER PRIMARY KEY,
    gateway_id       INTEGER NOT NULL REFERENCES gateway(id) ON DELETE RESTRICT,
    space_id         INTEGER REFERENCES space(id) ON DELETE SET NULL,  -- where the controller is installed
    system           TEXT    NOT NULL DEFAULT 'fire'
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    protocol         TEXT    NOT NULL,                 -- 'simplex', 'bacnet', 'modbus', 'snmp'...
    ref              TEXT    NOT NULL,                 -- fire node no., BACnet device instance, Modbus unit id
    name             TEXT    NOT NULL,
    vendor           TEXT,
    model            TEXT,
    firmware_version TEXT,
    conn_state       TEXT    NOT NULL DEFAULT 'unknown'
                     CHECK (conn_state IN ('online','offline','unknown')),
    last_contact     INTEGER CHECK (last_contact > 0),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (gateway_id, protocol, ref)
) STRICT;
CREATE INDEX ix_controller_space_id ON controller(space_id) WHERE space_id IS NOT NULL;

-- Device classification: rules, aggregation, symbols and permissions key off these,
-- never off vendor strings. Vendor types are mapped once in vendor_type_map.
CREATE TABLE device_category (
    id               INTEGER PRIMARY KEY,
    code             TEXT    NOT NULL UNIQUE,          -- detector, manual_call_point, monitor_input...
    system           TEXT    NOT NULL DEFAULT 'fire'
                     CHECK (system IN ('fire','bms','energy','access','cctv','other')),
    name             TEXT    NOT NULL,
    is_physical      INTEGER NOT NULL DEFAULT 1 CHECK (is_physical IN (0,1)),  -- 0 = virtual/controller-generated point
    sort_order       INTEGER NOT NULL DEFAULT 0,
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;

-- Our device type (req 15, 20). id 0 = unknown / unmapped.
CREATE TABLE device_type (
    id                 INTEGER PRIMARY KEY,            -- 0 = unknown / unmapped
    code               TEXT    NOT NULL UNIQUE,        -- smoke_detector, heat_detector, aux_relay...
    device_category_id INTEGER NOT NULL REFERENCES device_category(id) ON DELETE RESTRICT,
    name               TEXT    NOT NULL,
    has_analog         INTEGER NOT NULL DEFAULT 0 CHECK (has_analog IN (0,1)),   -- sensitivity/dirtiness trending
    can_disable        INTEGER NOT NULL DEFAULT 1 CHECK (can_disable IN (0,1)),
    can_test           INTEGER NOT NULL DEFAULT 0 CHECK (can_test IN (0,1)),
    default_symbol     TEXT,                           -- icon used on floor plans
    created_at         INTEGER NOT NULL CHECK (created_at > 0),
    updated_at         INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version        INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1)
) STRICT;
CREATE INDEX ix_device_type_device_category_id ON device_type(device_category_id);

-- Vendor/controller type string -> our device_type (stored upper-case, so 'High Speed Bus' and 'HIGH SPEED BUS' match)
CREATE TABLE vendor_type_map (
    id               INTEGER PRIMARY KEY,
    vendor           TEXT    NOT NULL,                 -- 'Simplex'
    vendor_type      TEXT    NOT NULL,                 -- e.g. 'SMOKE DETECTOR' (upper-case)
    device_type_id   INTEGER NOT NULL REFERENCES device_type(id) ON DELETE RESTRICT,
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (vendor, vendor_type)
) STRICT;
CREATE INDEX ix_vendor_type_map_device_type_id ON vendor_type_map(device_type_id);

-- Logical device / point (req 15, 18, 20). Master data: discovery_state marks removal, never hard-deleted.
CREATE TABLE device (
    id               INTEGER PRIMARY KEY,
    controller_id    INTEGER NOT NULL REFERENCES controller(id) ON DELETE RESTRICT,
    address          TEXT    NOT NULL,                 -- normalised key, unique per controller:
                                                       --   fire 'L1-M35', BACnet 'AI:3', Modbus 'HR:40001'
    address_json     TEXT    NOT NULL DEFAULT '{}'     -- protocol parts, e.g. {"loop":1,"point":"M35"}
                     CHECK (json_valid(address_json) AND json_type(address_json) = 'object'),
                                                       --   or {"object_type":"analogInput","instance":3}
    device_type_id   INTEGER NOT NULL DEFAULT 0 REFERENCES device_type(id) ON DELETE RESTRICT,  -- our classification; raw vendor type is on device_hardware
    source_label     TEXT,                             -- label reported by the controller
    local_label      TEXT,                             -- commissioning label (requirement 20)
    space_id         INTEGER REFERENCES space(id) ON DELETE SET NULL,  -- logical location; plan position is in plan_placement
    attributes_json  TEXT    NOT NULL DEFAULT '{}'     -- raw vendor attributes, never guessed
                     CHECK (json_valid(attributes_json) AND json_type(attributes_json) = 'object'),
    discovery_state  TEXT    NOT NULL DEFAULT 'present'
                     CHECK (discovery_state IN ('present','missing','removed')),
    created_at       INTEGER NOT NULL CHECK (created_at > 0),
    updated_at       INTEGER NOT NULL CHECK (updated_at > 0),
    updated_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    UNIQUE (controller_id, address)
) STRICT;
CREATE INDEX ix_device_space_id       ON device(space_id);
CREATE INDEX ix_device_device_type_id ON device(device_type_id);

-- Physical device units and addresses over time. device (above) is the logical point and holds
-- the CURRENT controller/address used to match incoming events; this table keeps every unit
-- and address the point has had, so a replaced or readdressed device keeps all its history.
-- Telemetry trends and advisory baselines restart from the current row's installed_at.
CREATE TABLE device_hardware (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES device(id) ON DELETE RESTRICT,
    controller_id    INTEGER NOT NULL REFERENCES controller(id) ON DELETE RESTRICT,  -- address while this unit was installed
    address          TEXT    NOT NULL,
    address_json     TEXT    NOT NULL DEFAULT '{}'
                     CHECK (json_valid(address_json) AND json_type(address_json) = 'object'),
    serial           TEXT,                             -- if the controller reports it
    model            TEXT,
    vendor_type      TEXT,                             -- raw type string reported by the controller (e.g. 'SMOKE DETECTOR');
                                                       -- the single source for unmapped-type review and re-mapping
    installed_at     INTEGER NOT NULL CHECK (installed_at > 0),
    removed_at       INTEGER CHECK (removed_at > 0),   -- NULL = currently installed
    reason           TEXT    NOT NULL DEFAULT 'commissioned'
                     CHECK (reason IN ('commissioned','replaced','moved','readdressed')),
    changed_by_user_account_id INTEGER REFERENCES user_account(id) ON DELETE RESTRICT,
    CHECK (removed_at IS NULL OR removed_at >= installed_at)
) STRICT;
CREATE UNIQUE INDEX ux_device_hardware_current ON device_hardware(device_id) WHERE removed_at IS NULL;
CREATE INDEX ix_device_hardware_device_id_installed_at ON device_hardware(device_id, installed_at);
CREATE INDEX ix_device_hardware_controller_id ON device_hardware(controller_id);

-- Free-form site tags for grouping that types cannot express (e.g. 'kitchen', 'server room', 'critical').
-- Pure child of device: CASCADE.
CREATE TABLE device_tag (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    tag              TEXT    NOT NULL COLLATE NOCASE,
    UNIQUE (device_id, tag)
) STRICT;
CREATE INDEX ix_device_tag_tag ON device_tag(tag);

-- Current state, one row per device (fast dashboard reads; req 1, 3, 15).
-- A device can be in several states at once (e.g. trouble + supervisory, or alarm + test),
-- so all active states are kept as a JSON array; primary_state is the most important one,
-- derived by the service from alarm_class precedence, and used for colours, sorting and counts.
-- Pure child (current-value cache, history is in device_state_history): CASCADE.
CREATE TABLE device_state (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL UNIQUE REFERENCES device(id) ON DELETE CASCADE,
    states_json      TEXT    NOT NULL DEFAULT '["normal"]'   -- all active states, e.g. ["trouble","supervisory"]
                     CHECK (json_valid(states_json) AND json_type(states_json) = 'array'),
    primary_state    TEXT    NOT NULL DEFAULT 'normal',      -- highest-precedence entry of states_json
    is_disabled      INTEGER NOT NULL DEFAULT 0 CHECK (is_disabled IN (0,1)),
    is_stale         INTEGER NOT NULL DEFAULT 0 CHECK (is_stale IN (0,1)),
    analog_json      TEXT                              -- latest sensitivity, dirtiness, values
                     CHECK (analog_json IS NULL OR (json_valid(analog_json) AND json_type(analog_json) = 'object')),
    updated_src_time INTEGER CHECK (updated_src_time > 0),   -- source time of the last state/value CHANGE
    updated_rcv_time INTEGER NOT NULL CHECK (updated_rcv_time > 0),  -- receive time of the last state/value CHANGE
    last_seen_at     INTEGER CHECK (last_seen_at > 0)  -- receive time of the last message of any kind about this device,
                                                       -- even if nothing changed. Kept live in memory and written at most
                                                       -- once a minute per device. Not an offline signal for fire points
                                                       -- (panels report only on change); use controller/gateway health.
) STRICT;

-- State changes over time (requirement 17), subject to retention
CREATE TABLE device_state_history (
    id               INTEGER PRIMARY KEY,
    device_id        INTEGER NOT NULL REFERENCES device(id) ON DELETE RESTRICT,
    old_states_json  TEXT    CHECK (old_states_json IS NULL OR (json_valid(old_states_json) AND json_type(old_states_json) = 'array')),
    new_states_json  TEXT    NOT NULL CHECK (json_valid(new_states_json) AND json_type(new_states_json) = 'array'),
    new_primary_state TEXT   NOT NULL,                 -- for quick filtering of history
    src_time         INTEGER CHECK (src_time > 0),
    rcv_time         INTEGER NOT NULL CHECK (rcv_time > 0)
) STRICT;
CREATE INDEX ix_device_state_history_device_id_rcv_time ON device_state_history(device_id, rcv_time);
