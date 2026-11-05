'use strict';
// Minimal SQL text utilities: comment stripping and top-level splitting of CREATE TABLE bodies.
// Comment-, string- and parenthesis-aware; enough for SQLite DDL as written in db/schema.

/** Remove -- and /* *\/ comments, leaving string and identifier literals intact. */
function stripComments(sql) {
  let out = '';
  for (let i = 0; i < sql.length; i++) {
    const c = sql[i], n = sql[i + 1];
    if (c === "'" || c === '"' || c === '`' || c === '[') {
      const close = c === '[' ? ']' : c;
      let j = i + 1;
      for (; j < sql.length; j++) {
        if (sql[j] === close) {
          if (close !== ']' && sql[j + 1] === close) { j++; continue; } // doubled quote escape
          break;
        }
      }
      out += sql.slice(i, j + 1);
      i = j;
    } else if (c === '-' && n === '-') {
      while (i < sql.length && sql[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && n === '*') {
      i += 2;
      while (i < sql.length && !(sql[i] === '*' && sql[i + 1] === '/')) i++;
      i++;
      out += ' ';
    } else {
      out += c;
    }
  }
  return out;
}

/** Collapse whitespace after stripping comments: the normal form used for schema comparison. */
function normalise(sql) {
  return stripComments(sql || '').replace(/\s+/g, ' ').replace(/\s*([(),])\s*/g, '$1').trim();
}

/** Split text on commas at parenthesis depth 0 (outside string literals). */
function splitTopLevel(text) {
  const parts = [];
  let depth = 0, cur = '', quote = null;
  for (const c of text) {
    if (quote) { cur += c; if (c === quote) quote = null; continue; }
    if (c === "'" || c === '"') { quote = c; cur += c; continue; }
    if (c === '(') depth++;
    if (c === ')') depth--;
    if (c === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

const TABLE_CONSTRAINT = /^(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN)\b/i;

/**
 * Parse a CREATE TABLE statement into column definitions and table constraints.
 * Returns { name, columns: [{name, def}], constraints: [text], options: 'STRICT, WITHOUT ROWID' }.
 */
function parseCreateTable(sql) {
  const clean = stripComments(sql);
  const m = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`[]?(\w+)["`\]]?\s*\(/i.exec(clean);
  if (!m) throw new Error('not a CREATE TABLE: ' + sql.slice(0, 60));
  const start = m.index + m[0].length;
  let depth = 1, i = start, quote = null;
  for (; i < clean.length && depth > 0; i++) {
    const c = clean[i];
    if (quote) { if (c === quote) quote = null; continue; }
    if (c === "'" || c === '"') quote = c;
    else if (c === '(') depth++;
    else if (c === ')') depth--;
  }
  const body = clean.slice(start, i - 1);
  const options = clean.slice(i).replace(/;\s*$/, '').trim();
  const columns = [], constraints = [];
  for (const part of splitTopLevel(body)) {
    if (TABLE_CONSTRAINT.test(part)) constraints.push(part);
    else columns.push({ name: part.split(/\s+/)[0].replace(/["`[\]]/g, ''), def: part });
  }
  return { name: m[1], columns, constraints, options };
}

/** Extract every CHECK (...) expression from a piece of DDL text. */
function checkExpressions(text) {
  const out = [];
  const re = /\bCHECK\s*\(/gi;
  let m;
  while ((m = re.exec(text))) {
    let depth = 1, i = re.lastIndex;
    for (; i < text.length && depth > 0; i++) {
      if (text[i] === '(') depth++;
      else if (text[i] === ')') depth--;
    }
    out.push(text.slice(re.lastIndex, i - 1));
    re.lastIndex = i;
  }
  return out;
}

module.exports = { stripComments, normalise, splitTopLevel, parseCreateTable, checkExpressions };
