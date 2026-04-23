'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// ── linuxWrapper — file, terminal, dialog APIs ────────────────────────────────
// Used by assistant.html and any injected UI
contextBridge.exposeInMainWorld('linuxWrapper', {
  openTerminal:     ()             => ipcRenderer.invoke('linux-wrapper:open-terminal'),
  openFileManager:  (targetPath)   => ipcRenderer.invoke('linux-wrapper:open-file-manager', targetPath),
  showOpenDialog:   (options = {}) => ipcRenderer.invoke('linux-wrapper:show-open-dialog', options),
  showSaveDialog:   (options = {}) => ipcRenderer.invoke('linux-wrapper:show-save-dialog', options),
  readTextFile:     (filePath)     => ipcRenderer.invoke('linux-wrapper:read-text-file', filePath),
  writeTextFile:    (filePath, content) => ipcRenderer.invoke('linux-wrapper:write-text-file', filePath, content),
  revealPath:       (targetPath)   => ipcRenderer.invoke('linux-wrapper:reveal-path', targetPath),
  status:           ()             => ipcRenderer.invoke('linux-wrapper:status'),
});

// ── electronAPI — shell/navigation helpers ───────────────────────────────────
// Used by assistant.html's "Open Perplexity" button: window.electronAPI.openExternal(url)
contextBridge.exposeInMainWorld('electronAPI', {
  openExternal: (url) => ipcRenderer.invoke('linux-wrapper:open-external', url),
});
