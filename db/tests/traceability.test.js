'use strict';
// TRACEABILITY.md must cover every ID in the architecture appendices (req 1-123, T1-T18, G01-G12),
// each exactly once, with all seven columns filled.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { ROOT } = require('./helpers');

const arch = fs.readFileSync(path.join(ROOT, 'docs/reference/architecture_roadmap_v1.2.md'), 'utf8');
const trace = fs.readFileSync(path.join(ROOT, 'docs/db/TRACEABILITY.md'), 'utf8');

function architectureIds() {
  const reqs = [...arch.matchAll(/^\*\*(\d+) (P\d)\*\*/gm)].map((m) => ({ id: m[1], priority: m[2] }));
  const targets = [...arch.matchAll(/^\|\s*\**(T\d+|G\d{2})\**\s*\|/gm)].map((m) => ({ id: m[1] }));
  return [...reqs, ...targets];
}

function traceRows() {
  return trace.split(/\r?\n/)
    .filter((l) => /^\|\s*(\d+|T\d+|G\d{2})\s/.test(l))
    .map((l) => {
      const cells = l.split('|').slice(1, -1).map((c) => c.trim());
      return { id: cells[0].split(/\s/)[0], cells };
    });
}

test('architecture appendices parse to 123 requirements, 18 targets and 12 GMA tests', () => {
  const ids = architectureIds().map((x) => x.id);
  assert.equal(ids.filter((i) => /^\d+$/.test(i)).length, 123);
  assert.equal(new Set(ids.filter((i) => /^T/.test(i))).size, 18);
  assert.equal(new Set(ids.filter((i) => /^G/.test(i))).size, 12);
});

test('every architecture ID has exactly one complete row', () => {
  const rows = traceRows();
  const byId = new Map();
  for (const r of rows) byId.set(r.id, (byId.get(r.id) || 0) + 1);
  const ids = [...new Set(architectureIds().map((x) => x.id))];
  assert.deepEqual(ids.filter((i) => !byId.has(i)), [], 'IDs missing from TRACEABILITY.md');
  assert.deepEqual([...byId].filter(([, n]) => n > 1).map(([i]) => i), [], 'IDs listed more than once');
  assert.deepEqual([...byId.keys()].filter((i) => !ids.includes(i)), [], 'IDs not in the architecture document');
  for (const r of rows) {
    assert.equal(r.cells.length, 7, `row ${r.id} must have 7 columns`);
    assert.ok(r.cells.every((c) => c.length), `row ${r.id} has an empty cell`);
    assert.match(r.cells[2], /^[YN]$/, `row ${r.id}: DB relevant? must be Y or N`);
    assert.match(r.cells[6], /^(Covered|Partial|Gap|Not measured|N\/A)/, `row ${r.id}: unknown status`);
    if (r.cells[2] === 'N') assert.equal(r.cells[6], 'N/A', `row ${r.id}: N rows have status N/A`);
  }
});

test('requirement priorities match the architecture document', () => {
  const rows = new Map(traceRows().map((r) => [r.id, r.cells[1]]));
  for (const { id, priority } of architectureIds().filter((x) => x.priority)) {
    assert.equal(rows.get(id), priority, `priority of req ${id}`);
  }
});
