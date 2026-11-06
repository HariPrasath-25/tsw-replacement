# Floor plan replacement — transaction script (req 39, G7, ADR-012)

This is how the service uploads, confirms, commits and rejects a floor plan revision. The SQL blocks below are **executed verbatim by `db/tests/tenancy.test.js`**, so this document and the tests can't drift apart. If you change a block, the test changes with it.

## Rules the schema enforces

| Rule | Enforced by |
|---|---|
| At most one `current` and one `draft` revision per space | `ux_floor_plan_current`, `ux_floor_plan_draft` |
| `revision_no` = max + 1 per space; `replaces_floor_plan_id` = the current plan at upload | `trg_floor_plan_revision_ins` |
| The same image can't be uploaded twice while it is live (draft or current) | `ux_floor_plan_space_id_sha256` (partial) |
| draft → current \| rejected; current → superseded; nothing else | `trg_floor_plan_status` |
| A draft is promoted only after its replaced plan is superseded and no placement `needs_review` | `trg_floor_plan_status` |
| Revision content (file, dimensions, hash) is immutable | `trg_floor_plan_content_immutable` |
| Placements of superseded / rejected revisions are frozen; `needs_review` only on a draft | `trg_plan_placement_ins` / `_upd` / `_del` |
| A placement's target is in the plan's site | `trg_plan_placement_ins` / `_upd` |

## How the service runs a block

1. `BEGIN IMMEDIATE`.
2. Run the statements in order with the named parameters.
3. Check the affected-row counts noted under each block. If a count is wrong, `ROLLBACK`.
4. On any error, `ROLLBACK`. `RAISE(ABORT)` undoes only the failing statement, not the whole transaction, so the service must roll back explicitly.
5. `COMMIT`. Only after COMMIT returns does the UI show the new state (req 97).

Every block also writes an `audit_log` row in the same transaction. That part is M9, and the audit insert isn't shown here.

## 1. upload-draft

The service has validated the file (req 29 limits, dimensions, sha256) and stored it under `storage_path`. Running this block does two things:

- It creates the draft revision.
- It copies every placement of the current revision onto the draft as `needs_review`, at the same relative position (x and y are fractions of the plan size, so they carry over to a resized image).

The current revision is not touched.

```sql name=upload-draft
INSERT INTO floor_plan (space_id, revision_no, replaces_floor_plan_id, status, status_changed_at,
                        file_name, mime_type, width_px, height_px, size_bytes, sha256, storage_path,
                        uploaded_by_user_account_id, uploaded_at, created_at, updated_at, updated_by_user_account_id)
SELECT :space_id,
       IFNULL((SELECT max(revision_no) FROM floor_plan WHERE space_id = :space_id), 0) + 1,
       (SELECT id FROM floor_plan WHERE space_id = :space_id AND status = 'current'),
       'draft', :now,
       :file_name, :mime_type, :width_px, :height_px, :size_bytes, :sha256, :storage_path,
       :user_id, :now, :now, :now, :user_id;

INSERT INTO plan_placement (floor_plan_id, device_id, controller_id, gateway_id, x, y, rotation_deg, symbol, status,
                            placed_by_user_account_id, placed_at, created_at, updated_at, updated_by_user_account_id)
SELECT d.id, p.device_id, p.controller_id, p.gateway_id, p.x, p.y, p.rotation_deg, p.symbol, 'needs_review',
       p.placed_by_user_account_id, p.placed_at, :now, :now, :user_id
  FROM floor_plan d
  JOIN plan_placement p ON p.floor_plan_id = d.replaces_floor_plan_id
 WHERE d.space_id = :space_id AND d.status = 'draft';
```

**Expected row counts and failures:**
- The first INSERT affects exactly 1 row.
- A `UNIQUE constraint failed: … floor_plan.space_id, floor_plan.sha256` error means the image is the same as the current plan or the pending draft.
- A failure on `ux_floor_plan_draft` means a draft is already pending, so the user must commit or reject it first.

## 2. confirm-placement

The user confirms each placement against the new image. They can move it in the same step. Optimistic concurrency applies (convention 10).

```sql name=confirm-placement
UPDATE plan_placement
   SET x = :x, y = :y, rotation_deg = :rotation_deg, status = 'placed',
       updated_at = :now, updated_by_user_account_id = :user_id, row_version = row_version + 1
 WHERE id = :placement_id AND row_version = :row_version AND status = 'needs_review';
```

**Expected row count:** exactly 1. A count of 0 means another session changed the row: reload it.

On the draft, placements can also be added (status `placed`) or deleted, for example for a device that is no longer on the drawing. Those are ordinary INSERTs and DELETEs on the draft revision.

## 3. commit-draft

This promotes the draft. The order is forced by `ux_floor_plan_current`: supersede first, then promote. If any placement still `needs_review`, the second statement aborts with `floor_plan: placements still need review` and the service rolls back.

```sql name=commit-draft
UPDATE floor_plan
   SET status = 'superseded', status_changed_at = :now,
       updated_at = :now, updated_by_user_account_id = :user_id, row_version = row_version + 1
 WHERE id = (SELECT replaces_floor_plan_id FROM floor_plan WHERE id = :draft_id AND status = 'draft');

UPDATE floor_plan
   SET status = 'current', status_changed_at = :now,
       updated_at = :now, updated_by_user_account_id = :user_id, row_version = row_version + 1
 WHERE id = :draft_id AND status = 'draft' AND row_version = :draft_row_version;
```

**Expected row counts:**
- The first UPDATE affects 1 row, or 0 for the first plan of a space.
- The second UPDATE must affect exactly 1 row.

Afterwards, the superseded revision and its placements are frozen history.

## 4. reject-draft

The user rejects the replacement. The current revision and its placements were never modified, so nothing has to be restored: the previous image and placements are exactly as they were (req 39). The rejected draft and its placements are kept, frozen, as history.

```sql name=reject-draft
UPDATE floor_plan
   SET status = 'rejected', status_changed_at = :now,
       updated_at = :now, updated_by_user_account_id = :user_id, row_version = row_version + 1
 WHERE id = :draft_id AND status = 'draft' AND row_version = :draft_row_version;
```

**Expected row count:** exactly 1.

Once a draft is rejected, its image can be uploaded again as a new revision, because the sha256 dedupe covers only draft and current revisions.
