#!/usr/bin/env node
'use strict';
const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const TOKEN = process.env.FS_BRIDGE_TOKEN || '';
const EXEC_ALLOW = process.env.FS_BRIDGE_EXEC_ALLOW === '1';
const PORT = parseInt(process.env.FS_BRIDGE_PORT || '7779', 10);

function auth(req) {
  const h = req.headers['authorization'] || '';
  return h === `Bearer ${TOKEN}`;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', c => data += c);
    req.on('end', () => {
      try { resolve(JSON.parse(data || '{}')); }
      catch(e) { resolve({}); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  if (!auth(req)) {
    res.writeHead(401);
    return res.end(JSON.stringify({ ok: false, error: 'unauthorized' }));
  }
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const route = url.pathname;

  if (route === '/ping' && req.method === 'GET') {
    res.writeHead(200);
    return res.end(JSON.stringify({ ok: true, pong: true }));
  }

  if (route === '/exec' && req.method === 'POST') {
    if (!EXEC_ALLOW) {
      res.writeHead(403);
      return res.end(JSON.stringify({ ok: false, error: 'exec disabled' }));
    }
    const body = await readBody(req);
    const cmd = body.cmd || '';
    if (!cmd) {
      res.writeHead(400);
      return res.end(JSON.stringify({ ok: false, error: 'no cmd' }));
    }
    exec(cmd, { shell: '/bin/bash', timeout: 120000, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      res.writeHead(200);
      res.end(JSON.stringify({
        ok: !err || err.code !== undefined,
        exit_code: err ? (err.code || 1) : 0,
        stdout: stdout || '',
        stderr: stderr || ''
      }));
    });
    return;
  }

  if (route === '/write' && req.method === 'POST') {
    const body = await readBody(req);
    const fpath = body.path || '';
    const content = body.content || '';
    if (!fpath) {
      res.writeHead(400);
      return res.end(JSON.stringify({ ok: false, error: 'no path' }));
    }
    try {
      fs.mkdirSync(path.dirname(fpath), { recursive: true });
      fs.writeFileSync(fpath, content, 'utf8');
      res.writeHead(200);
      res.end(JSON.stringify({ ok: true }));
    } catch(e) {
      res.writeHead(500);
      res.end(JSON.stringify({ ok: false, error: e.message }));
    }
    return;
  }

  if (route === '/read' && req.method === 'GET') {
    const fpath = url.searchParams.get('path') || '';
    if (!fpath) {
      res.writeHead(400);
      return res.end(JSON.stringify({ ok: false, error: 'no path' }));
    }
    try {
      const content = fs.readFileSync(fpath, 'utf8');
      res.writeHead(200);
      res.end(JSON.stringify({ ok: true, content }));
    } catch(e) {
      res.writeHead(500);
      res.end(JSON.stringify({ ok: false, error: e.message }));
    }
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ ok: false, error: 'not found' }));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`fs-bridge listening on 127.0.0.1:${PORT}`);
});
