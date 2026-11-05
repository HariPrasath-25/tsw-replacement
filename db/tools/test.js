#!/usr/bin/env node
'use strict';
// npm test — run every db/tests/**/*.test.js with node:test.
// Collects files explicitly so the same command works on Node 20 (no glob) and Node 22+.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const dir = path.resolve(__dirname, '..', 'tests');
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) { if (e.name !== 'helpers') walk(p); } else if (e.name.endsWith('.test.js')) files.push(p);
  }
})(dir);
files.sort();
if (!files.length) { console.error('no test files found'); process.exit(1); }

const r = spawnSync(process.execPath, ['--test', ...process.argv.slice(2), ...files], { stdio: 'inherit' });
process.exit(r.status === null ? 1 : r.status);
