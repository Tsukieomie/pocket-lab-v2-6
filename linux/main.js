'use strict';
const {
  app, BrowserWindow, shell, Menu, ipcMain, dialog, session
} = require('electron');
const fs = require('fs');
const fsPromises = require('fs/promises');
const path = require('path');
const { spawn } = require('child_process');

// ── Mode flag ─────────────────────────────────────────────────────────────────
const IS_ASSISTANT = process.argv.includes('--load-assistant');

// ── URLs ──────────────────────────────────────────────────────────────────────
const COMPUTER_URL = 'https://www.perplexity.ai/computer/new';
const HOME_URL     = 'https://www.perplexity.ai/';
const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Perplexity/Comet';

// ── GPU / platform flags ──────────────────────────────────────────────────────
app.commandLine.appendSwitch('enable-gpu-rasterization');
app.commandLine.appendSwitch('enable-zero-copy');
app.commandLine.appendSwitch('enable-hardware-overlays', 'single-fullscreen,single-on-top,underlay');
app.commandLine.appendSwitch('ignore-gpu-blocklist');
app.commandLine.appendSwitch('enable-accelerated-video-decode');
app.commandLine.appendSwitch('enable-features', 'VaapiVideoDecoder,VaapiVideoEncoder,CanvasOopRasterization,ParallelDownloading');
app.commandLine.appendSwitch('disable-software-rasterizer');
app.commandLine.appendSwitch('ozone-platform', 'x11');
app.commandLine.appendSwitch('disable-restore-session-state');
app.commandLine.appendSwitch('no-restore-last-session');
app.commandLine.appendSwitch('disable-session-crashed-bubble');
app.commandLine.appendSwitch('disable-crash-reporter');

// ── Paths ─────────────────────────────────────────────────────────────────────
const HOME_DIR      = app.getPath('home');
const USER_DATA_DIR = app.getPath('userData');

// ── Terminal / file-manager candidates ───────────────────────────────────────
const TERMINAL_CANDIDATES = [
  ['x-terminal-emulator'], ['gnome-terminal'], ['konsole'],
  ['xfce4-terminal'], ['mate-terminal'], ['lxterminal'],
  ['tilix'], ['alacritty'], ['kitty'], ['xterm'],
];
const FILE_MANAGER_CANDIDATES = [
  ['xdg-open'], ['nautilus'], ['dolphin'],
  ['thunar'], ['nemo'], ['pcmanfm'],
];

// ── Helpers ───────────────────────────────────────────────────────────────────
function withinUserScope(p) {
  if (!p || typeof p !== 'string') return false;
  const resolved = path.resolve(p);
  return resolved === HOME_DIR ||
    resolved.startsWith(HOME_DIR + path.sep) ||
    resolved === USER_DATA_DIR ||
    resolved.startsWith(USER_DATA_DIR + path.sep);
}

async function spawnFirstAvailable(candidates, args = [], opts = {}) {
  for (const cmd of candidates) {
    const [bin, ...pre] = cmd;
    try {
      await new Promise((resolve, reject) => {
        const child = spawn(bin, [...pre, ...args], { detached: true, stdio: 'ignore', ...opts });
        child.once('error', reject);
        child.once('spawn', () => { child.unref(); resolve(); });
      });
      return true;
    } catch (_) {}
  }
  return false;
}

async function openTerminal() {
  const ok = await spawnFirstAvailable(TERMINAL_CANDIDATES, [], { cwd: HOME_DIR });
  if (!ok) throw new Error('No supported terminal emulator found.');
  return { ok: true, cwd: HOME_DIR };
}

async function openFileManager(targetPath) {
  const safePath = targetPath && withinUserScope(targetPath) ? path.resolve(targetPath) : HOME_DIR;
  const opened = await spawnFirstAvailable(FILE_MANAGER_CANDIDATES, [safePath]);
  if (!opened) await shell.openPath(safePath);
  return { ok: true, path: safePath };
}

function isAuthUrl(url) {
  return ['accounts.google.com', 'appleid.apple.com', 'apple.com',
    'github.com/login', 'auth.perplexity.ai', 'clerk.', '/oauth',
    '/login', '/signin', '/auth', 'sso.'].some(d => url.includes(d));
}
function isPerplexityUrl(url) {
  return url.startsWith('https://www.perplexity.ai') || url.startsWith('https://perplexity.ai');
}
function isAllowed(url) {
  return isPerplexityUrl(url) || isAuthUrl(url) || url.startsWith('file://') || url === 'about:blank';
}

// ── Permissions ───────────────────────────────────────────────────────────────
function installPermissionHandlers(sess) {
  const allowed = new Set([
    'clipboard-read', 'clipboard-sanitized-write', 'display-capture',
    'fullscreen', 'geolocation', 'media', 'mediaKeySystem', 'midi',
    'notifications', 'pointerLock',
  ]);
  sess.setPermissionRequestHandler((_wc, permission, cb) => cb(allowed.has(permission)));
  sess.setPermissionCheckHandler((_wc, permission) => allowed.has(permission));
}

// ── Icon b64 for favicon injection ───────────────────────────────────────────
let iconB64 = '';
try {
  iconB64 = 'data:image/png;base64,' +
    fs.readFileSync(path.join(__dirname, 'perplexity_icon_v3_32.png')).toString('base64');
} catch (_) {}

function injectBranding(webContents) {
  webContents.executeJavaScript(`
    (function() {
      ['icon','shortcut icon'].forEach(function(rel) {
        var el = document.querySelector("link[rel='" + rel + "']") || document.createElement('link');
        el.rel = rel; el.type = 'image/png'; el.href = '${iconB64}';
        document.head.appendChild(el);
      });
      document.title = 'Perplexity Computer';
    })();
  `).catch(() => {});
}

// ── IPC bridge (used by assistant.html via preload.js) ───────────────────────
let mainWin = null; // reference for dialog parent

ipcMain.handle('linux-wrapper:open-terminal', async () => openTerminal());
ipcMain.handle('linux-wrapper:open-file-manager', async (_e, p) => openFileManager(p));
ipcMain.handle('linux-wrapper:open-external', async (_e, url) => {
  if (typeof url === 'string' && (url.startsWith('http://') || url.startsWith('https://'))) {
    shell.openExternal(url);
  }
});
ipcMain.handle('linux-wrapper:show-open-dialog', async (_e, options = {}) => {
  const result = await dialog.showOpenDialog(mainWin, {
    defaultPath: HOME_DIR, properties: ['openFile'], ...options,
  });
  return { canceled: result.canceled, filePaths: (result.filePaths || []).filter(withinUserScope) };
});
ipcMain.handle('linux-wrapper:show-save-dialog', async (_e, options = {}) => {
  const result = await dialog.showSaveDialog(mainWin, {
    defaultPath: path.join(HOME_DIR, 'perplexity-export.txt'), ...options,
  });
  if (!result.filePath || !withinUserScope(result.filePath)) return { canceled: true };
  return { canceled: result.canceled, filePath: result.filePath };
});
ipcMain.handle('linux-wrapper:read-text-file', async (_e, filePath) => {
  if (!withinUserScope(filePath)) throw new Error('Access denied.');
  const resolved = path.resolve(filePath);
  const content = await fsPromises.readFile(resolved, 'utf8');
  return { filePath: resolved, content };
});
ipcMain.handle('linux-wrapper:write-text-file', async (_e, filePath, content) => {
  if (!withinUserScope(filePath)) throw new Error('Access denied.');
  const resolved = path.resolve(filePath);
  await fsPromises.mkdir(path.dirname(resolved), { recursive: true });
  await fsPromises.writeFile(resolved, String(content), 'utf8');
  return { ok: true, filePath: resolved };
});
ipcMain.handle('linux-wrapper:reveal-path', async (_e, targetPath) => {
  if (!withinUserScope(targetPath)) throw new Error('Access denied.');
  shell.showItemInFolder(path.resolve(targetPath));
  return { ok: true };
});
ipcMain.handle('linux-wrapper:status', async () => ({
  mode: IS_ASSISTANT ? 'assistant' : 'computer',
  homeDir: HOME_DIR,
  platform: process.platform,
}));

// ── Assistant window (narrow sidebar mode) ────────────────────────────────────
function createAssistantWindow() {
  const win = new BrowserWindow({
    width: 460,
    height: 900,
    minWidth: 360,
    minHeight: 600,
    backgroundColor: '#0b0d1a',
    title: 'Perplexity Assistant',
    icon: path.join(__dirname, 'icon.png'),
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false,
      preload: path.join(__dirname, 'preload.js'),
      partition: 'persist:perplexity',
    },
  });

  mainWin = win;
  win.webContents.setUserAgent(UA);

  win.webContents.on('did-finish-load', () => {
    const url = win.webContents.getURL();
    if (!url.startsWith('file://') && !isAllowed(url)) {
      win.loadURL(COMPUTER_URL);
    } else if (iconB64) {
      injectBranding(win.webContents);
    }
  });

  win.webContents.on('will-navigate', (event, url) => {
    if (!isAllowed(url)) { event.preventDefault(); win.loadURL(COMPUTER_URL); }
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  win.once('ready-to-show', () => win.show());
  win.on('closed', () => app.quit());

  // Load the local assistant UI
  win.loadFile(path.join(__dirname, 'assistant.html'));
  return win;
}

// ── Main Computer window ──────────────────────────────────────────────────────
function createComputerWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 480,
    minHeight: 600,
    backgroundColor: '#0b0d1a',
    title: 'Perplexity Computer',
    icon: path.join(__dirname, 'icon.png'),
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false,
      preload: path.join(__dirname, 'preload.js'),
      partition: 'persist:perplexity',
    },
  });

  mainWin = win;
  win.webContents.setUserAgent(UA);

  win.webContents.setWindowOpenHandler(({ url }) => {
    if (isAllowed(url)) {
      return {
        action: 'allow',
        overrideBrowserWindowOptions: { width: 520, height: 720,
          webPreferences: { nodeIntegration: false, contextIsolation: true } },
      };
    }
    shell.openExternal(url);
    return { action: 'deny' };
  });

  win.webContents.on('will-navigate', (event, url) => {
    if (!isAllowed(url)) { event.preventDefault(); win.loadURL(COMPUTER_URL); }
  });

  win.webContents.on('did-finish-load', () => {
    const url = win.webContents.getURL();
    if (!isAllowed(url)) {
      win.loadURL(COMPUTER_URL);
    } else {
      injectBranding(win.webContents);
    }
  });

  win.once('ready-to-show', () => { win.show(); win.maximize(); });

  const menu = Menu.buildFromTemplate([{
    label: 'Perplexity',
    submenu: [
      { label: 'Computer (AI)',  accelerator: 'Alt+N',             click: () => win.loadURL(COMPUTER_URL) },
      { label: 'Home',           accelerator: 'CmdOrCtrl+Shift+H', click: () => win.loadURL(HOME_URL) },
      { type: 'separator' },
      { label: 'Reload',         accelerator: 'CmdOrCtrl+R',       click: () => win.reload() },
      { label: 'Hard Reload',    accelerator: 'CmdOrCtrl+Shift+R', click: () => win.webContents.reloadIgnoringCache() },
      { label: 'DevTools',       accelerator: 'CmdOrCtrl+Shift+I', click: () => win.webContents.openDevTools() },
      { type: 'separator' },
      { label: 'Open Assistant', accelerator: 'CmdOrCtrl+Shift+A', click: () => {
          const existing = BrowserWindow.getAllWindows().find(w => w.getTitle() === 'Perplexity Assistant');
          if (existing) { existing.focus(); } else { createAssistantWindow(); }
        }
      },
      { type: 'separator' },
      { label: 'Quit',           accelerator: 'CmdOrCtrl+Q',       click: () => app.quit() },
    ],
  }]);
  Menu.setApplicationMenu(menu);

  win.loadURL(COMPUTER_URL);
  return win;
}

// ── App entry point ───────────────────────────────────────────────────────────
app.whenReady().then(() => {
  installPermissionHandlers(session.defaultSession);
  if (IS_ASSISTANT) {
    createAssistantWindow();
  } else {
    createComputerWindow();
  }
});

app.on('window-all-closed', () => app.quit());
app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    IS_ASSISTANT ? createAssistantWindow() : createComputerWindow();
  }
});
