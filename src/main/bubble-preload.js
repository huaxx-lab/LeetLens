const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bubbleApi', {
  ask: () => ipcRenderer.send('ask-selected-text'),
  dismiss: () => ipcRenderer.send('dismiss-selection-bubble')
});
