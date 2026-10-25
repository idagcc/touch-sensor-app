const { contextBridge, ipcRenderer } = require('electron');
const isOutput = location.pathname.endsWith('output.html');
contextBridge.exposeInMainWorld('player', {
  model: () => ipcRenderer.invoke(isOutput ? 'output:model' : 'model:get'),
  action: action => ipcRenderer.invoke('player:action', action),
  save: config => ipcRenderer.invoke('settings:save', config),
  reload: () => ipcRenderer.invoke('media:reload'),
  connection: settings => ipcRenderer.invoke('serial:toggle', settings),
  refresh: () => ipcRenderer.invoke('serial:refresh'),
  chooseFolder: () => ipcRenderer.invoke('folder:choose'),
  mediaFolder: () => ipcRenderer.invoke('folder:media'),
  configFile: () => ipcRenderer.invoke('folder:config'),
  output: fullscreen => ipcRenderer.invoke('output:show', fullscreen),
  hideOutput: () => ipcRenderer.invoke('output:hide'),
  progress: value => { if (isOutput) ipcRenderer.send('output:progress', value); },
  ended: () => { if (isOutput) ipcRenderer.send('output:ended'); },
  error: message => { if (isOutput) ipcRenderer.send('output:error', message); },
  ready: () => { if (isOutput) ipcRenderer.send('output:ready'); },
  subscribe: callback => { const listener = (_event, value) => callback(value); ipcRenderer.on('model', listener); return () => ipcRenderer.removeListener('model', listener); }
});
