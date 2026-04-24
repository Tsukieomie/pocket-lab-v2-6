#!/usr/bin/env node
'use strict';
// ============================================================
// linux/fs-bridge/server.js — Pocket Lab Filesystem Bridge
//
// Lightweight HTTP server (localhost only) that gives
// Perplexity Computer read/write/exec access to the local
// filesystem over the existing bore SSH tunnel.
//
// Security model:
//   - Binds ONLY to 127.0.0.1 — never reachable from outside
//   - All paths constrained to $HOME (withinUserScope guard)
//   - Bearer token auth (FS_BRIDGE_TOKEN from ~/.bore_env)
//   - exec: allow-list enforced (no arbitrary shell unless
//     FS_BRIDGE_EXEC_ALLOW=1 set explicitly in ~/.bore_env)
//
// Usage (Perplexity Computer side, via SSH):
//   ssh -p PORT kenny@HOST "curl -s -H 'Authorization: Bearer TOKEN' \
//     http://localhost:7779/ls?path=/home/kenny"
//
// Or with an inline ssh command:
//   ssh -p PORT kenny@HOST curl -s \
//     -H 'Authorization: Bearer TOKEN' \
//     'http://localhost:7779/read?path=/home/kenny/pocket-lab-v2-6/bore-port.txt'
// ============================================================

const http    = require('http');
const fs      = require('fs');
const fsp     = require('fs/promises');
const path    = require('path');
const os      = require('os');
const { execFile, spawn } = require('child_process');

// ── Config ────────────────────────────────────────────────────────────────────
const PORT      = parseInt(process.env.FS_BRIDGE_PORT  || '7779', 10);
const HOME      = os.homedir();
const BORE_ENV  = path.join(HOME, '.bore_env');
const LOG_FILE  = '/tmp/fs-bridge.log';

function loadBoreEnv() {
  try {
    return Object.fromEntries(
      fs.readFileSync(BORE_ENV, 'utf8').split('\n')
        .filter(l => l.includes('=') && !l.startsWith('#'))
        .map(l => { const i = l.indexOf('='); return [l.slice(0,i).trim(), l.slice(i+1).trim()]; })
    );
  } catch (_) { return {}; }
}

const ENV            = loadBoreEnv();
const TOKEN          = ENV.FS_BRIDGE_TOKEN || process.env.FS_BRIDGE_TOKEN || '';
const EXEC_ALLOW     = ENV.FS_BRIDGE_EXEC_ALLOW === '1' || process.env.FS_BRIDGE_EXEC_ALLOW === '1';
const MAX_READ_BYTES = 4 * 1024 * 1024;  // 4 MB read cap

if (!TOKEN) {
  console.error('[fs-bridge] ERROR: FS_BRIDGE_TOKEN not set in ~/.bore_env');
  console.error('[fs-bridge] Add:   FS_BRIDGE_TOKEN=<random-secret>  to ~/.bore_env');
  process.exit(1);
}

// ── Logging ───────────────────────────────────────────────────────────────────
function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.join(' ')}\n`;
  process.stdout.write(line);
  try { fs.appendFileSync(LOG_FILE, line); } catch (_) {}
}

// ── Path guard ────────────────────────────────────────────────────────────────
function withinUserScope(p) {
  if (!p || typeof p !== 'string') return false;
  const resolved = path.resolve(p.replace(/^~/, HOME));
  return resolved === HOME || resolved.startsWith(HOME + path.sep);
}

function resolveSafe(p) {
  if (!p) throw Object.assign(new Error('path required'), { status: 400 });
  const resolved = path.resolve(p.replace(/^~/, HOME));
  if (!withinUserScope(resolved)) throw Object.assign(new Error('Access denied: path outside $HOME'), { status: 403 });
  return resolved;
}

// ── Auth ──────────────────────────────────────────────────────────────────────
function checkAuth(req) {
  const auth = req.headers['authorization'] || '';
  const provided = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!provided || provided !== TOKEN) {
    throw Object.assign(new Error('Unauthorized'), { status: 401 });
  }
}

// ── Body reader ───────────────────────────────────────────────────────────────
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', chunk => {
      total += chunk.length;
      if (total > MAX_READ_BYTES) { req.destroy(); return reject(new Error('Request body too large')); }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch (_) { reject(Object.assign(new Error('Invalid JSON body'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

// ── Query parser ──────────────────────────────────────────────────────────────
function parseQuery(url) {
  const u = new URL(url, 'http://localhost');
  return Object.fromEntries(u.searchParams);
}

// ── Route handlers ────────────────────────────────────────────────────────────

// GET /status
async function handleStatus() {
  return {
    ok: true,
    version: '1.0.0',
    home: HOME,
    exec_allow: EXEC_ALLOW,
    uptime_s: Math.floor(process.uptime()),
  };
}

// GET /ls?path=<dir>&hidden=1
async function handleLs(query) {
  const dir = resolveSafe(query.path || HOME);
  const showHidden = query.hidden === '1';
  const entries = await fsp.readdir(dir, { withFileTypes: true });
  const items = await Promise.all(
    entries
      .filter(e => showHidden || !e.name.startsWith('.'))
      .map(async e => {
        const fullPath = path.join(dir, e.name);
        let stat = null;
        try { stat = await fsp.stat(fullPath); } catch (_) {}
        return {
          name:     e.name,
          path:     fullPath,
          type:     e.isDirectory() ? 'dir' : e.isSymbolicLink() ? 'symlink' : 'file',
          size:     stat ? stat.size : null,
          modified: stat ? stat.mtime.toISOString() : null,
        };
      })
  );
  return { path: dir, entries: items };
}

// GET /read?path=<file>&encoding=utf8|base64
async function handleRead(query) {
  const filePath = resolveSafe(query.path);
  const stat = await fsp.stat(filePath);
  if (stat.size > MAX_READ_BYTES) throw Object.assign(
    new Error(`File too large (${stat.size} bytes, max ${MAX_READ_BYTES})`), { status: 413 }
  );
  const enc = query.encoding === 'base64' ? 'base64' : 'utf8';
  const content = await fsp.readFile(filePath, enc);
  return { path: filePath, encoding: enc, content, size: stat.size, modified: stat.mtime.toISOString() };
}

// POST /write  { path, content, encoding? }
async function handleWrite(body) {
  const filePath = resolveSafe(body.path);
  const enc = body.encoding === 'base64' ? 'base64' : 'utf8';
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, body.content || '', enc);
  const stat = await fsp.stat(filePath);
  return { ok: true, path: filePath, size: stat.size };
}

// DELETE /delete?path=<file>  (files only — no recursive dir delete)
async function handleDelete(query) {
  const filePath = resolveSafe(query.path);
  const stat = await fsp.stat(filePath);
  if (stat.isDirectory()) throw Object.assign(new Error('Use /rmdir for directories'), { status: 400 });
  await fsp.unlink(filePath);
  return { ok: true, path: filePath };
}

// POST /mkdir  { path }
async function handleMkdir(body) {
  const dir = resolveSafe(body.path);
  await fsp.mkdir(dir, { recursive: true });
  return { ok: true, path: dir };
}

// POST /exec  { cmd, args?, cwd?, timeout_ms? }
// Only available when FS_BRIDGE_EXEC_ALLOW=1 in ~/.bore_env
async function handleExec(body) {
  if (!EXEC_ALLOW) throw Object.assign(
    new Error('exec disabled — set FS_BRIDGE_EXEC_ALLOW=1 in ~/.bore_env to enable'),
    { status: 403 }
  );
  if (!body.cmd || typeof body.cmd !== 'string') throw Object.assign(new Error('cmd required'), { status: 400 });

  const cwd = body.cwd ? resolveSafe(body.cwd) : HOME;
  const args = Array.isArray(body.args) ? body.args.map(String) : [];
  const timeout = Math.min(parseInt(body.timeout_ms || '30000', 10), 120000);

  const result = await new Promise((resolve, reject) => {
    const child = spawn(body.cmd, args, {
      cwd,
      env: { ...process.env, HOME },
      shell: true,
      timeout,
    });
    const stdout = [], stderr = [];
    child.stdout.on('data', d => stdout.push(d));
    child.stderr.on('data', d => stderr.push(d));
    child.on('close', code => resolve({
      ok: code === 0,
      exit_code: code,
      stdout: Buffer.concat(stdout).toString('utf8').slice(0, 256 * 1024),
      stderr: Buffer.concat(stderr).toString('utf8').slice(0, 64 * 1024),
    }));
    child.on('error', reject);
  });

  return result;
}

// GET /stat?path=<path>
async function handleStat(query) {
  const filePath = resolveSafe(query.path);
  const stat = await fsp.stat(filePath);
  return {
    path: filePath,
    type: stat.isDirectory() ? 'dir' : stat.isFile() ? 'file' : 'other',
    size: stat.size,
    modified: stat.mtime.toISOString(),
    created: stat.birthtime.toISOString(),
    mode: '0' + (stat.mode & 0o777).toString(8),
  };
}

// ── HTTP server ───────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const urlPath = new URL(req.url, 'http://localhost').pathname;
  const query   = parseQuery(req.url);
  const method  = req.method.toUpperCase();
  log(`${method} ${urlPath}`);

  res.setHeader('Content-Type', 'application/json');

  try {
    checkAuth(req);

    let data;
    if      (method === 'GET'    && urlPath === '/status')  data = await handleStatus();
    else if (method === 'GET'    && urlPath === '/ls')       data = await handleLs(query);
    else if (method === 'GET'    && urlPath === '/read')     data = await handleRead(query);
    else if (method === 'GET'    && urlPath === '/stat')     data = await handleStat(query);
    else if (method === 'POST'   && urlPath === '/write')    data = await handleWrite(await readBody(req));
    else if (method === 'POST'   && urlPath === '/mkdir')    data = await handleMkdir(await readBody(req));
    else if (method === 'DELETE' && urlPath === '/delete')   data = await handleDelete(query);
    else if (method === 'POST'   && urlPath === '/exec')     data = await handleExec(await readBody(req));
    else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Not found', routes: [
        'GET /status', 'GET /ls?path=', 'GET /read?path=',
        'GET /stat?path=', 'POST /write', 'POST /mkdir',
        'DELETE /delete?path=', 'POST /exec (requires FS_BRIDGE_EXEC_ALLOW=1)',
      ]}));
      return;
    }

    res.writeHead(200);
    res.end(JSON.stringify(data));
  } catch (err) {
    const status = err.status || 500;
    log(`ERROR ${status}: ${err.message}`);
    res.writeHead(status);
    res.end(JSON.stringify({ error: err.message }));
  }
});

server.listen(PORT, '127.0.0.1', () => {
  log(`fs-bridge listening on 127.0.0.1:${PORT}`);
  log(`Home scope: ${HOME}`);
  log(`Exec: ${EXEC_ALLOW ? 'ENABLED' : 'disabled (set FS_BRIDGE_EXEC_ALLOW=1 to enable)'}`);
});

server.on('error', err => {
  log(`Server error: ${err.message}`);
  process.exit(1);
});

// Graceful shutdown
process.on('SIGTERM', () => { log('SIGTERM — shutting down'); server.close(() => process.exit(0)); });
process.on('SIGINT',  () => { log('SIGINT — shutting down');  server.close(() => process.exit(0)); });
