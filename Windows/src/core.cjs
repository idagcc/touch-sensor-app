const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { performance } = require('node:perf_hooks');

const actions = new Set(['toggle', 'play', 'pause', 'reset', 'restart', 'quit']);
const defaults = {
  serial: { port: '', baudRate: 9600, autoConnect: true, framing: 'newline', debounceMs: 180, startupDelayMs: 2000, reconnectInitialDelayMs: 500, reconnectMaxDelayMs: 10000, heartbeatTimeoutMs: 0 },
  commands: { '0': 'toggle', '1': 'reset' },
  output: { width: 1920, height: 1080, displayID: 0, scale: 'fit', openOnLaunch: false, fullscreenOnLaunch: false },
  videos: { holdingFolder: 'media/holding', playbackFolder: 'media/playback', endBehavior: 'holding', muteHolding: true, volume: 1 }
};
function normalize(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw Error('Settings must be a JSON object.');
  const c = { serial: { ...defaults.serial, ...raw.serial }, output: { ...defaults.output, ...raw.output }, videos: { ...defaults.videos, ...raw.videos }, commands: { ...(raw.commands ?? defaults.commands) } };
  const number = (v, min, max) => Number.isInteger(v) && v >= min && v <= max;
  if (!number(c.output.width, 1, 16384) || !number(c.output.height, 1, 16384)) throw Error('Canvas dimensions must be 1–16384.');
  if (!['fit', 'fill', 'stretch'].includes(c.output.scale) || !['holding', 'freeze', 'quit'].includes(c.videos.endBehavior)) throw Error('Invalid scaling or end behavior.');
  if (typeof c.serial.port !== 'string' || c.serial.port.length > 1024 || ![1200,2400,4800,9600,19200,38400,57600,115200,230400].includes(c.serial.baudRate)) throw Error('Invalid serial port or baud rate.');
  if (!['newline', 'byte'].includes(c.serial.framing) || !number(c.serial.debounceMs, 0, 10000) || !number(c.serial.startupDelayMs, 0, 30000)) throw Error('Invalid serial framing or timing.');
  if (!number(c.serial.reconnectInitialDelayMs, 100, 60000) || !number(c.serial.reconnectMaxDelayMs, c.serial.reconnectInitialDelayMs, 60000)) throw Error('Invalid reconnect delays.');
  if (c.serial.heartbeatTimeoutMs !== 0 && (!number(c.serial.heartbeatTimeoutMs, 250, 600000) || c.serial.framing !== 'newline')) throw Error('Heartbeat timeout requires newline framing and 250–600000 ms.');
  if (typeof c.serial.autoConnect !== 'boolean' || typeof c.output.openOnLaunch !== 'boolean' || typeof c.output.fullscreenOnLaunch !== 'boolean' || !Number.isInteger(c.output.displayID)) throw Error('Invalid connection or display settings.');
  if (typeof c.videos.muteHolding !== 'boolean' || !Number.isFinite(c.videos.volume) || c.videos.volume < 0 || c.videos.volume > 1) throw Error('Volume must be 0–1.');
  for (const field of ['holdingFolder', 'playbackFolder']) if (typeof c.videos[field] !== 'string' || !c.videos[field].trim()) throw Error('Both video folders are required.');
  if (!Object.keys(c.commands).length) throw Error('At least one command is required.');
  for (const [key, value] of Object.entries(c.commands)) {
    if (!key || key.trim() !== key || /[\r\n]/.test(key) || Buffer.byteLength(key) > 256 || ['READY', 'HEARTBEAT'].includes(key) || !actions.has(value)) throw Error('Invalid command mapping.');
    if (c.serial.framing === 'byte' && !/^[!-~]$/.test(key)) throw Error('Byte mode needs one printable ASCII character per command.');
  }
  if (c.serial.deviceIdentity != null) {
    const id = c.serial.deviceIdentity;
    if (!number(id.vendorID, 0, 65535) || !number(id.productID, 0, 65535) || (!id.serialNumber && !id.pnpId)) throw Error('Invalid saved USB identity. Select the Windows COM port again.');
  }
  return c;
}
function readConfig(root) {
  const file = path.join(root, 'config.json');
  if (!fs.existsSync(file)) saveConfig(root, structuredClone(defaults));
  return normalize(JSON.parse(fs.readFileSync(file, 'utf8')));
}
function saveConfig(root, value) {
  const config = normalize(value);
  fs.mkdirSync(root, { recursive: true });
  const file = path.join(root, 'config.json');
  const temp = file + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(config, null, 2) + '\n');
  fs.renameSync(temp, file);
  return config;
}
function mediaFile(root, folder) {
  const directory = path.resolve(root, folder);
  fs.mkdirSync(directory, { recursive: true });
  return fs.readdirSync(directory, { withFileTypes: true }).filter(f => f.isFile() && !f.name.startsWith('.') && /\.(mp4|mov|m4v)$/i.test(f.name)).map(f => f.name).sort((a,b) => a.localeCompare(b, undefined, { numeric: true })).map(f => path.join(directory, f))[0] ?? null;
}
class Framer {
  constructor(mode = 'newline') { this.mode = mode; this.reset(); }
  reset() { this.bytes = []; this.discard = false; }
  feed(buffer) {
    const frames = [];
    for (const byte of buffer) {
      if (this.mode === 'byte') { if (byte > 32 && byte < 127) frames.push(String.fromCharCode(byte)); }
      else if (byte === 10 || byte === 13) {
        if (!this.discard && this.bytes.length) {
          const value = new TextDecoder('utf-8', { fatal: false }).decode(Uint8Array.from(this.bytes)).trim();
          if (value && !value.includes('\ufffd')) frames.push(value);
        }
        this.reset();
      } else if (!this.discard) {
        if (this.bytes.length < 256) this.bytes.push(byte);
        else { this.bytes = []; this.discard = true; }
      }
    }
    return frames;
  }
}
class Router {
  reset() { this.last = null; this.time = -Infinity; }
  constructor() { this.reset(); }
  route(command, config, now = performance.now()) {
    const action = config.commands[command];
    if (!actions.has(action)) return null;
    if (this.last === command && now - this.time < config.serial.debounceMs) return null;
    this.last = command; this.time = now; return action;
  }
}
function nextState(state, action) {
  if (action === 'reset') return 'holding';
  if (action === 'toggle') return state === 'playing' ? 'paused' : 'playing';
  if (action === 'pause') return state === 'playing' ? 'paused' : state;
  if (action === 'play' || action === 'restart') return 'playing';
  return state;
}
function identity(port) {
  if (!port?.vendorId || !port?.productId || (!port.serialNumber && !port.pnpId)) return null;
  return { vendorID: parseInt(port.vendorId,16), productID: parseInt(port.productId,16), serialNumber: port.serialNumber || null, pnpId: port.pnpId || null };
}
function resolvePort(settings, ports) {
  const id = settings.deviceIdentity;
  if (!id) return ports.find(p => p.path === settings.port) ?? null;
  const matches = ports.filter(p => { const actual = identity(p); return actual && actual.vendorID === id.vendorID && actual.productID === id.productID && (id.serialNumber ? actual.serialNumber === id.serialNumber : actual.pnpId === id.pnpId); });
  return matches.find(p => p.path === settings.port) ?? (matches.length === 1 ? matches[0] : null);
}
class SerialSession extends EventEmitter {
  constructor(Port, options = {}) {
    super(); this.Port = Port; this.list = options.list ?? (() => Port.list()); this.now = options.now ?? (() => performance.now());
    this.settings = { ...defaults.serial }; this.ports = []; this.port = null; this.epoch = 0; this.desired = false; this.suspended = false; this.phase = 'disconnected'; this.retry = 0; this.nextAttempt = 0; this.chain = Promise.resolve(); this.lastScan = -Infinity;
    this.timer = setInterval(() => this.tick().catch(e => this.lost(this.epoch, e.message)), options.interval ?? 250); this.timer.unref();
  }
  emitStatus(phase, message) { if (phase !== this.phase || message !== this.message) { this.phase = phase; this.message = message; this.emit('status', { phase, message, device: this.device }); } }
  queue(fn) { const work = this.chain.then(fn, fn); this.chain = work.catch(() => {}); return work; }
  async scan() {
    if (this.scanning) return;
    this.scanning = true;
    try { const ports = await this.list(); if (!this.destroyed && JSON.stringify(ports) !== JSON.stringify(this.ports)) { this.ports = ports; this.emit('ports', ports); } this.lastScan = this.now(); }
    catch (error) { this.emit('diagnostic', 'Cannot refresh serial ports: ' + error.message); }
    finally { this.scanning = false; }
  }
  async closePort() {
    const port = this.port;
    if (port?.isOpen) await new Promise(resolve => port.close(() => resolve()));
    if (this.port === port) this.port = null;
    this.device = null;
  }
  start(settings) {
    const token = ++this.epoch; this.settings = { ...settings }; this.desired = !!settings.port; this.retry = 0;
    return this.queue(async () => { await this.closePort(); if (token !== this.epoch) return; await this.scan(); this.nextAttempt = 0; this.emitStatus(this.desired ? 'waiting' : 'disconnected', this.desired ? 'Looking for selected Arduino' : 'Select a COM port'); });
  }
  configure(settings) {
    const changed = ['port','baudRate','framing'].some(k => settings[k] !== this.settings[k]) || (this.settings.deviceIdentity && JSON.stringify(settings.deviceIdentity) !== JSON.stringify(this.settings.deviceIdentity));
    this.settings = { ...settings };
    if (changed && this.desired) return this.start(settings);
    if (!settings.autoConnect && this.phase === 'waiting') return this.stop();
    return Promise.resolve();
  }
  stop() { ++this.epoch; this.desired = false; this.emitStatus('disconnected', 'Disconnected by operator'); return this.queue(() => this.closePort()); }
  async suspend() { this.suspended = true; ++this.epoch; await this.queue(() => this.closePort()); if (this.desired) this.emitStatus('suspended', 'Serial suspended during sleep'); }
  resume() { this.suspended = false; this.retry = 0; this.nextAttempt = this.now() + 1000; if (this.desired && this.settings.autoConnect) this.emitStatus('waiting', 'Mac/PC woke · waiting for USB'); else this.stop(); }
  async dispose() { this.destroyed = true; clearInterval(this.timer); await this.stop(); }
  lost(token, message) {
    if (token !== this.epoch || this.destroyed) return;
    ++this.epoch;
    this.queue(() => this.closePort());
    if (this.desired && this.settings.autoConnect) {
      const delay = Math.min(this.settings.reconnectMaxDelayMs, this.settings.reconnectInitialDelayMs * 2 ** Math.min(this.retry++, 16));
      this.nextAttempt = this.now() + delay; this.emitStatus('waiting', message + ' · retry in ' + delay/1000 + ' s');
    } else { this.desired = false; this.emitStatus('disconnected', message); }
  }
  async ready(token) {
    if (this.finishing || token !== this.epoch || this.phase !== 'settling') return;
    this.finishing = true;
    const port = this.port;
    try {
      await new Promise((resolve,reject) => port.flush(e => e ? reject(e) : resolve()));
      if (token !== this.epoch) return;
      this.framer.reset(); this.lastHeartbeat = this.now(); this.connectedSince = this.now();
      this.settings.port = this.device.path; this.settings.deviceIdentity = identity(this.device);
      this.emitStatus('connected', 'Connected · ' + this.device.path + ' · ' + this.settings.baudRate + ' baud');
    } catch (error) { this.lost(token, error.message); }
    finally { if (token === this.epoch) this.finishing = false; }
  }
  async open(device, token) {
    if (token !== this.epoch || !this.desired || this.suspended) return;
    this.device = device; this.framer = new Framer(this.settings.framing); this.frameCount = 0; this.frameWindow = this.now(); this.finishing = false;
    this.emitStatus('connecting', 'Opening ' + device.path);
    let port;
    try { port = new this.Port({ path: device.path, baudRate: this.settings.baudRate, autoOpen: false, lock: true, dataBits: 8, stopBits: 1, parity: 'none', rtscts: false, xon: false, xoff: false, highWaterMark: 4096 }); }
    catch (error) { this.lost(token, error.message); return; }
    this.port = port;
    port.on('error', error => this.lost(token, error.message));
    port.on('close', () => this.lost(token, 'Serial device disconnected'));
    port.on('data', bytes => {
      if (token !== this.epoch) return;
      if (bytes.length > 65536) { this.lost(token, 'Serial input overflow'); return; }
      for (const frame of this.framer.feed(bytes)) {
        if (token !== this.epoch) break;
        if (this.now() - this.frameWindow >= 1000) { this.frameWindow = this.now(); this.frameCount = 0; }
        if (++this.frameCount > 100) { this.lost(token, 'Serial message flood · check firmware'); break; }
        if (frame === 'HEARTBEAT') { this.lastHeartbeat = this.now(); continue; }
        if (frame === 'READY') { if (this.phase === 'settling') this.ready(token); continue; }
        if (this.phase === 'connected') this.emit('command', frame);
      }
    });
    try {
      await new Promise((resolve,reject) => port.open(e => e ? reject(e) : resolve()));
      if (token !== this.epoch) { if (port.isOpen) await new Promise(resolve => port.close(resolve)); if (this.port === port) this.port = null; return; }
      this.readyAt = this.now() + this.settings.startupDelayMs;
      this.emitStatus('settling', 'Arduino starting · waiting for READY or ' + this.settings.startupDelayMs + ' ms');
      if (this.settings.startupDelayMs === 0) await this.ready(token);
    } catch (error) { this.lost(token, error.message); }
  }
  async tick() {
    if (this.destroyed || this.suspended || this.ticking) return;
    this.ticking = true;
    try {
      if (this.now() - this.lastScan >= 1000) await this.scan();
      if (!this.desired) return;
      if (this.phase === 'settling' && this.now() >= this.readyAt) await this.ready(this.epoch);
      if (this.phase === 'connected') {
        if (this.now() - this.connectedSince >= 10000) this.retry = 0;
        if (this.settings.heartbeatTimeoutMs && this.now() - this.lastHeartbeat > this.settings.heartbeatTimeoutMs) this.lost(this.epoch, 'Arduino heartbeat timed out');
      } else if (this.phase === 'waiting' && !this.port && this.now() >= this.nextAttempt) {
        const device = resolvePort(this.settings, this.ports);
        if (!device) { this.emitStatus('waiting', 'Waiting for selected Arduino · reconnects automatically'); this.nextAttempt = this.now() + 500; return; }
        const token = ++this.epoch;
        this.emitStatus('connecting', 'Opening ' + device.path);
        await this.queue(() => this.open(device, token));
      }
    } finally { this.ticking = false; }
  }
}
module.exports = { defaults, normalize, readConfig, saveConfig, mediaFile, Framer, Router, nextState, identity, resolvePort, SerialSession, actions };
