const { app, BrowserWindow, ipcMain, protocol, net, screen, dialog, shell, powerMonitor, powerSaveBlocker } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { SerialPort } = require('serialport');
const core = require('./core.cjs');

protocol.registerSchemesAsPrivileged([{ scheme: 'touch', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);
const smoke = process.argv.includes('--smoke-test');
if (smoke) app.disableHardwareAcceleration();
if (!app.requestSingleInstanceLock()) { app.quit(); }
let control, output, serial, blocker, root, files = {}, quitting = false;
let model = { config: structuredClone(core.defaults), root: '', files: {}, ports: [], displays: [], serial: { phase: 'disconnected', message: 'Disconnected' }, state: 'holding', sequence: 0, revision: 0, lastAction: 'reset', progress: { time: 0, duration: 0 }, logs: [], outputVisible: false };
const router = new core.Router();
const locationFile = () => path.join(app.getPath('userData'), 'data-folder.json');
function log(message) { model.logs.push({ time: new Date().toLocaleTimeString(), message: String(message).slice(0,500) }); model.logs = model.logs.slice(-120); broadcast(); }
function broadcast() { for (const window of [control, output]) if (window && !window.isDestroyed()) window.webContents.send('model', model); }
function readRoot() {
  const index = process.argv.indexOf('--data-dir');
  if (index >= 0 && process.argv[index+1]) return path.resolve(process.argv[index+1]);
  try { const saved = JSON.parse(fs.readFileSync(locationFile(), 'utf8')).path; if (fs.existsSync(saved)) return saved; } catch {}
  const sibling = path.join(process.env.PORTABLE_EXECUTABLE_DIR || path.dirname(app.getPath('exe')), 'Touch Player Data');
  if (app.isPackaged && fs.existsSync(sibling)) return sibling;
  return app.isPackaged ? path.join(app.getPath('userData'), 'Touch Player Data') : path.join(__dirname, '..', '..', '.build', 'Windows Preview Data');
}
function seedIfNew() {
  if (fs.existsSync(root)) return;
  const seed = app.isPackaged ? path.join(process.resourcesPath, 'DefaultData') : path.join(__dirname, '..', 'data');
  fs.mkdirSync(path.dirname(root), { recursive: true });
  if (fs.existsSync(seed)) fs.cpSync(seed, root, { recursive: true }); else fs.mkdirSync(root, { recursive: true });
}
function reload() {
  const config = core.readConfig(root);
  const found = { holding: core.mediaFile(root, config.videos.holdingFolder), playback: core.mediaFile(root, config.videos.playbackFolder) };
  model.config = config; files = found; model.root = root;
  model.files = Object.fromEntries(Object.entries(found).map(([k,v]) => [k, v ? { name: path.basename(v), url: 'touch://media/' + k } : null]));
  model.revision++; router.reset(); serial?.configure(config.serial); act('reset');
  log('Loaded settings · holding: ' + (model.files.holding?.name || 'missing') + ' · playback: ' + (model.files.playback?.name || 'missing'));
}
function act(action) {
  if (!core.actions.has(action)) throw Error('Unknown player action');
  if (action === 'quit') { app.quit(); return; }
  if (['play','toggle','restart'].includes(action) && !files.playback) { log('Add a video to the playback folder, then reload.'); return; }
  model.state = core.nextState(model.state, action); model.lastAction = action; model.sequence++;
  log('Player → ' + action); broadcast();
}
function refreshDisplays() {
  model.displays = screen.getAllDisplays().map((d,i) => ({ id: d.id, name: d.label || ('Display ' + (i+1)), width: d.size.width, height: d.size.height }));
  broadcast();
}
function hideOutput() { if (output && !output.isDestroyed()) { output.setFullScreen(false); output.hide(); } model.outputVisible = false; broadcast(); control?.show(); control?.focus(); }
function showOutput(fullscreen) {
  const c = model.config.output;
  const display = screen.getAllDisplays().find(d => d.id === c.displayID) || screen.getPrimaryDisplay();
  output.setFullScreen(false);
  if (fullscreen) output.setBounds(display.bounds);
  else {
    const factor = Math.min(1, display.workArea.width*0.85/c.width, display.workArea.height*0.85/c.height);
    const width = Math.round(c.width*factor), height = Math.round(c.height*factor);
    output.setContentBounds({ x: Math.round(display.workArea.x+(display.workArea.width-width)/2), y: Math.round(display.workArea.y+(display.workArea.height-height)/2), width, height });
  }
  output.show(); output.setFullScreen(fullscreen); output.focus(); model.outputVisible = true; broadcast();
}
function safeWindow(options) {
  const window = new BrowserWindow({ backgroundColor: '#0e1214', autoHideMenuBar: true, ...options, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true, backgroundThrottling: false, autoplayPolicy: 'no-user-gesture-required' } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.on('render-process-gone', (_event, details) => { if (!quitting) { log('Video/window process stopped: ' + details.reason); if (window === output) { model.state = 'holding'; model.sequence++; } window.reload(); } });
  return window;
}
function trusted(event, role) {
  const window = BrowserWindow.fromWebContents(event.sender);
  const expected = role === 'output' ? output : control;
  if (window !== expected || event.senderFrame !== event.sender.mainFrame || !event.senderFrame.url.startsWith('touch://app/')) throw Error('Untrusted request');
}
function handle(channel, callback) { ipcMain.handle(channel, async (event, ...args) => { trusted(event, 'control'); return callback(...args); }); }

app.whenReady().then(async () => {
  protocol.handle('touch', async request => {
    const url = new URL(request.url);
    let file;
    if (url.hostname === 'media' && ['holding','playback'].includes(url.pathname.slice(1))) file = files[url.pathname.slice(1)];
    else if (url.hostname === 'app') {
      const allowed = new Set(['index.html','output.html','styles.css','control.js','output.js']);
      const name = url.pathname.slice(1); if (allowed.has(name)) file = path.join(__dirname, 'ui', name);
    }
    if (!file || !fs.existsSync(file)) return new Response('Not found', { status: 404 });
    const response = await net.fetch(pathToFileURL(file).href, { headers: request.headers });
    const headers = new Headers(response.headers); headers.set('Cache-Control','no-store');
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  });
  root = readRoot(); seedIfNew();
  serial = new core.SerialSession(SerialPort);
  serial.on('ports', ports => { model.ports = ports; broadcast(); });
  serial.on('diagnostic', log);
  serial.on('status', status => {
    model.serial = status; log(status.message);
    if (status.phase === 'connected') {
      router.reset();
      const device = status.device;
      if (device && (model.config.serial.port !== device.path || JSON.stringify(model.config.serial.deviceIdentity) !== JSON.stringify(core.identity(device)))) {
        model.config.serial.port = device.path; model.config.serial.deviceIdentity = core.identity(device);
        try { core.saveConfig(root, model.config); } catch (error) { log('Could not remember Arduino: ' + error.message); }
      }
    }
  });
  let lastIgnored = 0;
  serial.on('command', command => { const action = router.route(command, model.config); if (action) act(action); else if (Date.now()-lastIgnored > 1000) { lastIgnored = Date.now(); log('Ignored / debounced serial input'); } });
  app.on('second-instance', () => { control?.show(); control?.focus(); });
  app.on('activate', () => control?.show());
  app.on('before-quit', () => { quitting = true; serial.dispose(); if (blocker && powerSaveBlocker.isStarted(blocker)) powerSaveBlocker.stop(blocker); });
  powerMonitor.on('suspend', () => serial.suspend()); powerMonitor.on('resume', () => serial.resume());
  blocker = powerSaveBlocker.start('prevent-display-sleep');
  control = safeWindow({ width: 1110, height: 870, minWidth: 980, minHeight: 760, title: 'Touch Player', show: !smoke });
  output = safeWindow({ width: 960, height: 540, title: 'Touch Player · Output', show: false });
  control.on('close', () => { quitting = true; app.quit(); });
  output.on('close', event => { if (!quitting) { event.preventDefault(); hideOutput(); } });
  output.on('leave-full-screen', () => broadcast());
  screen.on('display-added', refreshDisplays); screen.on('display-removed', () => { refreshDisplays(); if (model.outputVisible) showOutput(true); });
  handle('model:get', () => model);
  ipcMain.handle('output:model', event => { trusted(event, 'output'); return model; });
  ipcMain.handle('player:action', (event, action) => { const role = BrowserWindow.fromWebContents(event.sender) === output ? 'output' : 'control'; trusted(event, role); if (typeof action !== 'string') throw Error('Invalid action'); act(action); });
  handle('settings:save', raw => { const normalized = core.normalize(raw); core.saveConfig(root, normalized); reload(); return model; });
  handle('media:reload', () => { reload(); return model; });
  handle('serial:toggle', async patch => {
    if (serial.desired) await serial.stop();
    else {
      const config = core.normalize({ ...model.config, serial: { ...model.config.serial, port: patch?.port, baudRate: patch?.baudRate, autoConnect: patch?.autoConnect } });
      if (!config.serial.port) throw Error('Select a COM port first.');
      config.serial.deviceIdentity = core.identity(model.ports.find(p => p.path === config.serial.port));
      model.config = core.saveConfig(root,config); router.reset(); await serial.start(model.config.serial);
    }
    return model;
  });
  handle('serial:refresh', async () => { await serial.scan(); return model; });
  handle('folder:choose', async () => {
    const result = await dialog.showOpenDialog(control, { title: 'Choose Touch Player Data folder', defaultPath: root, properties: ['openDirectory','createDirectory'] });
    if (!result.canceled) { await serial.stop(); root = result.filePaths[0]; reload(); fs.mkdirSync(path.dirname(locationFile()), { recursive: true }); fs.writeFileSync(locationFile(), JSON.stringify({ path: root })); if (model.config.serial.autoConnect && model.config.serial.port) await serial.start(model.config.serial); }
    return model;
  });
  handle('folder:media', async () => { fs.mkdirSync(path.join(root,'media'), { recursive: true }); const error = await shell.openPath(path.join(root,'media')); if (error) throw Error(error); });
  handle('folder:config', () => shell.showItemInFolder(path.join(root,'config.json')));
  ipcMain.handle('output:show', (event, fullscreen) => { const role = BrowserWindow.fromWebContents(event.sender) === output ? 'output' : 'control'; trusted(event, role); if (typeof fullscreen !== 'boolean') throw Error('Invalid output mode'); showOutput(fullscreen); });
  ipcMain.handle('output:hide', event => { trusted(event, BrowserWindow.fromWebContents(event.sender) === output ? 'output' : 'control'); hideOutput(); });
  ipcMain.on('output:progress', (event, progress) => { trusted(event, 'output'); if (Number.isFinite(progress?.time) && Number.isFinite(progress?.duration)) { model.progress = { time: Math.max(0,progress.time), duration: Math.max(0,progress.duration) }; if (!control.isDestroyed()) control.webContents.send('model', model); } });
  ipcMain.on('output:ended', event => { trusted(event, 'output'); if (model.state !== 'playing') return; if (model.config.videos.endBehavior === 'quit') app.quit(); else if (model.config.videos.endBehavior === 'holding') act('reset'); else { model.state = 'finished'; model.sequence++; broadcast(); } });
  ipcMain.on('output:error', (event, message) => { trusted(event, 'output'); log('Video error: ' + String(message).slice(0,300)); act('reset'); });
  ipcMain.on('output:ready', event => { trusted(event, 'output'); if (smoke) runSmoke().catch(error => { console.error(error); app.exit(1); }); });
  try { reload(); } catch (error) { log('Cannot load data folder: ' + error.message); }
  refreshDisplays(); await serial.scan();
  await Promise.all([control.loadURL('touch://app/index.html'), output.loadURL('touch://app/output.html')]);
  if (!smoke && model.config.output.openOnLaunch) showOutput(model.config.output.fullscreenOnLaunch);
  if (!smoke && model.config.serial.autoConnect && model.config.serial.port) await serial.start(model.config.serial);
});
app.on('window-all-closed', () => app.quit());

async function runSmoke() {
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  const sample = () => output.webContents.executeJavaScript('window.touchPlayerSmokeSnapshot()');
  await delay(1000);
  act('toggle'); await delay(750);
  let snapshot = await sample();
  if (snapshot.state !== 'playing' || snapshot.playbackTime <= 0 || snapshot.playbackPaused) throw Error('Playback did not start: ' + JSON.stringify(snapshot));
  act('toggle'); await delay(100); const paused = await sample(); await delay(200); snapshot = await sample();
  if (!snapshot.playbackPaused || Math.abs(snapshot.playbackTime-paused.playbackTime) > 0.1) throw Error('Pause did not hold position');
  act('toggle'); await delay(200); snapshot = await sample(); if (snapshot.playbackPaused || snapshot.playbackTime <= paused.playbackTime) throw Error('Resume did not advance');
  act('reset'); await delay(150); snapshot = await sample(); if (snapshot.state !== 'holding' || !snapshot.playbackPaused || snapshot.playbackTime > 0.1) throw Error('Reset did not rewind and return to holding');
  act('toggle'); await delay(200); snapshot = await sample(); if (snapshot.playbackTime > 0.8 || snapshot.playbackPaused) throw Error('Play after reset did not start from zero');
  act('reset');
  console.log('Electron playback smoke test passed: play, pause, resume, holding, rewind.');
  app.quit();
}
