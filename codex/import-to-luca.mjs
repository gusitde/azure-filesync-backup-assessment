#!/usr/bin/env node
/**
 * codex/import-to-luca.mjs - import this library into a Luca codex checkout.
 *
 *   node codex/import-to-luca.mjs --luca-root <path-to-Luca-express-prod> [--seed] [--dry-run]
 *
 * What it does (idempotent):
 *   1. copies codex/*.md (entries) into <luca>/aios-core-apps/domains/design/apps/lucadesigns/codex/
 *      and codex/diagrams/*.mmd into <luca>/.../codex/diagrams/
 *   2. merges codex/ref-dispositions.json into <luca>/scripts/codex/ref-dispositions.json
 *      (kit-relative paths cited by the entries are recorded as external-repo references)
 *   3. runs <luca>/scripts/codex/validate-manifest.mjs on every copied entry; exits non-zero on
 *      the first error so a non-conforming entry never reaches blueprint.blueprints
 *   4. with --seed, runs <luca>/scripts/codex/seed-codex.mjs and prints the SQL to stdout
 *      (apply it the way the Luca playbooks do; this script never talks to a database)
 *
 * --dry-run copies nothing and only validates the entries in place (uses the Luca validator
 * against this repo's files).
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };
const flag = (name) => args.includes(name);

const lucaRoot = path.resolve(opt('--luca-root', process.env.LUCA_ROOT || ''));
if (!lucaRoot || !fs.existsSync(path.join(lucaRoot, 'scripts', 'codex', 'validate-manifest.mjs'))) {
  console.error('usage: node codex/import-to-luca.mjs --luca-root <Luca-express-prod checkout> [--seed] [--dry-run]');
  process.exit(2);
}
const CODEX_DIR = path.join(lucaRoot, 'aios-core-apps', 'domains', 'design', 'apps', 'lucadesigns', 'codex');
const entries = fs.readdirSync(here).filter((f) => f.endsWith('.md') && !f.startsWith('_') && f !== 'README.md');
const diagrams = fs.existsSync(path.join(here, 'diagrams')) ? fs.readdirSync(path.join(here, 'diagrams')).filter((f) => f.endsWith('.mmd')) : [];
const dryRun = flag('--dry-run');

function validate(files) {
  const r = spawnSync(process.execPath, [path.join(lucaRoot, 'scripts', 'codex', 'validate-manifest.mjs'), ...files], { cwd: lucaRoot, encoding: 'utf8' });
  process.stdout.write(r.stdout || '');
  process.stderr.write(r.stderr || '');
  return r.status ?? 1;
}

if (dryRun) {
  console.log(`dry run: validating ${entries.length} entries in place with ${lucaRoot}`);
  process.exit(validate(entries.map((f) => path.join(here, f))));
}

// 1. copy entries + diagrams
fs.mkdirSync(path.join(CODEX_DIR, 'diagrams'), { recursive: true });
let copied = 0;
for (const f of entries) { fs.copyFileSync(path.join(here, f), path.join(CODEX_DIR, f)); copied++; }
for (const f of diagrams) { fs.copyFileSync(path.join(here, 'diagrams', f), path.join(CODEX_DIR, 'diagrams', f)); copied++; }
console.log(`copied ${copied} files into ${CODEX_DIR}`);

// 2. merge dispositions
const dispSrc = path.join(here, 'ref-dispositions.json');
const dispDst = path.join(lucaRoot, 'scripts', 'codex', 'ref-dispositions.json');
if (fs.existsSync(dispSrc)) {
  const add = JSON.parse(fs.readFileSync(dispSrc, 'utf8'));
  let cur = {};
  if (fs.existsSync(dispDst)) { try { cur = JSON.parse(fs.readFileSync(dispDst, 'utf8')); } catch { cur = {}; } }
  const isArray = Array.isArray(cur);
  if (isArray) {
    const seen = new Set(cur.map((d) => d.ref || d.path));
    for (const d of Object.entries(add).map(([ref, v]) => ({ ref, ...v }))) if (!seen.has(d.ref)) cur.push(d);
  } else {
    for (const [k, v] of Object.entries(add)) if (!cur[k]) cur[k] = v;
  }
  fs.writeFileSync(dispDst, JSON.stringify(cur, null, 2) + '\n');
  console.log(`merged ${Object.keys(add).length} disposition(s) into ${path.relative(lucaRoot, dispDst)}`);
}

// 3. validate
const rc = validate(entries.map((f) => path.relative(lucaRoot, path.join(CODEX_DIR, f))));
if (rc !== 0) { console.error('validation failed - fix the entries before seeding'); process.exit(rc); }

// 4. seed (SQL to stdout)
if (flag('--seed')) {
  const r = spawnSync(process.execPath, [path.join(lucaRoot, 'scripts', 'codex', 'seed-codex.mjs')], { cwd: lucaRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  process.stdout.write(r.stdout || '');
  process.stderr.write(r.stderr || '');
  process.exit(r.status ?? 1);
}
console.log('done - entries copied and validated; run with --seed to emit the seed SQL');
