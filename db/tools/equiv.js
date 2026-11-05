#!/usr/bin/env node
'use strict';
// npm run db:equiv — compare the db/schema modules with the frozen Draft v2 reference.
// M0: the modules were identical to Draft v2. From M1 the schema changes on purpose, so this tool
//   * GUARDS that nothing from Draft v2 was removed: every table, column, index and trigger still
//     exists, either under its Draft v2 name or under the rename recorded in RENAMES below
//     (CLAUDE.md: removing a table or column from Draft v2 needs a human decision); and
//   * with --diff, LISTS every intended difference for review.

// Intentional renames since Draft v2, with the milestone and convention that drove them.
const RENAMES = {
  columns: {
    // M1, convention 6 (booleans named is_/has_/can_)
    'command_type.allow_schedule': 'can_schedule',
    'command_schedule.skip_if_alarm_active': 'is_skip_if_alarm_active',
    'command_schedule.enabled': 'is_enabled',
    'command.pin_verified': 'is_pin_verified',
    'session.locked': 'is_locked',
    'retention_policy.archive_first': 'is_archive_first',
    'backup_run.verified': 'is_verified',
    // M1, convention 2 / ADR-000 item 7 (FK named <role>_<table>_id)
    'floor_plan.uploaded_by': 'uploaded_by_user_account_id',
    'plan_placement.placed_by': 'placed_by_user_account_id',
    'gateway_hardware.changed_by': 'changed_by_user_account_id',
    'device_hardware.changed_by': 'changed_by_user_account_id',
    'alarm.acked_by': 'acked_by_user_account_id',
    'command_schedule.created_by': 'created_by_user_account_id',
    'command_schedule.approved_by': 'approved_by_user_account_id',
    'user_role.granted_by': 'granted_by_user_account_id',
    'quarantine.reviewed_by': 'reviewed_by_user_account_id',
    'setting.updated_by': 'updated_by_user_account_id',
    'retention_policy.updated_by': 'updated_by_user_account_id',
    'update_history.started_by': 'started_by_user_account_id',
  },
  objects: {
    // M1, convention 13 (ix_/ux_<table>_..., trg_<table>_...)
    'index ix_place_device': 'index ix_plan_placement_device_id',
    'index ux_place_device': 'index ux_plan_placement_device',
    'index ux_place_controller': 'index ux_plan_placement_controller',
    'index ux_place_gateway': 'index ux_plan_placement_gateway',
    'index ix_device_type': 'index ix_device_device_type_id',
    'index ix_device_space': 'index ix_device_space_id',
    'index ux_device_hw_current': 'index ux_device_hardware_current',
    'index ix_device_hw_device': 'index ix_device_hardware_device_id_installed_at',
    'index ix_device_tag': 'index ix_device_tag_tag',
    'index ix_dsh_device_time': 'index ix_device_state_history_device_id_rcv_time',
    'index ux_gateway_hw_current': 'index ux_gateway_hardware_current',
    'index ix_schedule_due': 'index ix_command_schedule_next_run_at',
    'index ux_group_role_scope': 'index ux_directory_group_role_scope',
    'index ix_audit_at': 'index ix_audit_log_at',
    'index ix_gwh_gateway_time': 'index ix_gateway_health_gateway_id_rcv_time',
    'index ix_update_started': 'index ix_update_history_started_at',
    'trigger trg_schedule_allowed': 'trigger trg_command_schedule_allowed',
    'trigger trg_schedule_allowed_upd': 'trigger trg_command_schedule_allowed_upd',
    'trigger trg_group_role_scope': 'trigger trg_directory_group_role_scope',
    'trigger trg_audit_no_update': 'trigger trg_audit_log_no_update',
    'trigger trg_audit_no_delete': 'trigger trg_audit_log_no_delete',
  },
};

const { REFERENCE_FILE, buildDatabase, buildFromFile, schemaRows, tableDetail } = require('./lib/schema');

/** Compare two DBs. Returns a list of human-readable differences (empty = equivalent). */
function compare(refDb, modDb) {
  const diffs = [];
  const key = (r) => `${r.type} ${r.name}`;
  const ref = new Map(schemaRows(refDb).map((r) => [key(r), r]));
  const mod = new Map(schemaRows(modDb).map((r) => [key(r), r]));
  for (const [k, r] of ref) {
    if (!mod.has(k)) diffs.push(`missing in modules: ${k}`);
    else if (mod.get(k).sql !== r.sql || mod.get(k).tbl_name !== r.tbl_name) {
      diffs.push(`different: ${k}\n    reference: ${r.sql}\n    modules:   ${mod.get(k).sql}`);
    }
  }
  for (const k of mod.keys()) if (!ref.has(k)) diffs.push(`extra in modules: ${k}`);

  const a = tableDetail(refDb), b = tableDetail(modDb);
  for (const t of Object.keys(a)) {
    if (!b[t]) continue; // already reported
    for (const part of ['list', 'columns', 'fks', 'indexes']) {
      if (JSON.stringify(a[t][part]) !== JSON.stringify(b[t][part])) diffs.push(`pragma ${part} differs for table ${t}`);
    }
  }
  return diffs;
}

/**
 * Nothing from the reference may disappear: returns a list of problems (empty = every Draft v2
 * table, column, index and trigger survives under its own name or its recorded rename).
 */
function guard(refDb, modDb, renames = RENAMES) {
  const problems = [];
  const key = (r) => `${r.type} ${r.name}`;
  const mod = new Set(schemaRows(modDb).map(key));
  for (const r of schemaRows(refDb)) {
    const k = key(r);
    const want = renames.objects[k] || k;
    if (!mod.has(want)) problems.push(`removed: ${k}${want !== k ? ` (expected as ${want})` : ''}`);
  }
  const a = tableDetail(refDb), b = tableDetail(modDb);
  for (const [t, d] of Object.entries(a)) {
    if (!b[t]) continue; // reported above
    const have = new Set(b[t].columns.map((c) => c.name));
    for (const c of d.columns) {
      const want = renames.columns[`${t}.${c.name}`] || c.name;
      if (!have.has(want)) problems.push(`removed column: ${t}.${c.name}${want !== c.name ? ` (expected as ${want})` : ''}`);
    }
  }
  for (const [from, to] of Object.entries(renames.columns)) {
    const [t] = from.split('.');
    if (!b[t] || !b[t].columns.some((c) => c.name === to)) problems.push(`stale rename: ${from} -> ${to} not in modules`);
  }
  return problems;
}

function run(referenceFile = REFERENCE_FILE) {
  const refDb = buildFromFile(referenceFile);
  const modDb = buildDatabase(':memory:', { seed: false });
  try {
    return { diffs: compare(refDb, modDb), problems: guard(refDb, modDb), objects: schemaRows(refDb).length };
  } finally {
    refDb.close();
    modDb.close();
  }
}

if (require.main === module) {
  try {
    const { diffs, problems, objects } = run();
    const list = process.argv.includes('--diff');
    if (list) for (const d of diffs) console.log('  ' + d);
    for (const p of problems) console.error('  GUARD ' + p);
    if (problems.length) {
      console.error(`db:equiv FAILED: ${problems.length} Draft v2 objects/columns missing without a recorded rename`);
      process.exit(1);
    }
    console.log(`db:equiv: all ${objects} Draft v2 objects and every Draft v2 column survive (renames recorded); `
      + `${diffs.length} intended differences${list ? '' : ' (run with --diff to list)'}`);
  } catch (e) {
    console.error('db:equiv FAILED: ' + e.message);
    process.exit(1);
  }
}

module.exports = { compare, guard, run, RENAMES };
