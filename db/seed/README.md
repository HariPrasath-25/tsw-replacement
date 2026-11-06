# Seed data

Ordered reference-data modules `NN_<area>.sql`, applied by `npm run db:build` after `db/schema`, in the same transaction. Each module is logged in `schema_version` as `seed/<name>`.

| Module | Contents | ADR |
|---|---|---|
| `01_lookups.sql` | system, vendor, protocol | ADR-005 |
| `02_alarm.sql` | alarm_class (req 6), device_state_code (proposed), condition (req 41) | ADR-006, ADR-007, ADR-008 |
| `03_rbac.sql` | permission (req 57, Section 13), built-in roles (req 56, Section 13), role-permission matrix | ADR-007 |

Rules (checked by `db/tests/seed.test.js`):
- **Idempotent.** Every statement is `INSERT … ON CONFLICT DO NOTHING`. Applying a module twice writes nothing.
- **Fixed ids** for lookup rows. Schema defaults depend on them, for example `controller.system_id DEFAULT 1` = fire. Link rows (`role_permission`) join by natural key (role name, permission code), not by id.
- **Deterministic.** `created_at` / `updated_at` = `1793923200000` (2026-11-06T00:00:00Z).
- **Fresh builds only.** Seeds don't update existing rows. After the schema freeze, reference-data changes ship as migrations.
