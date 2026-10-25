const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { SerialPortMock } = require('serialport');
const { defaults, normalize, saveConfig, readConfig, mediaFile, Framer, Router, nextState, identity, resolvePort, SerialSession } = require('../src/core.cjs');
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
async function until(predicate, timeout = 2000) { const end = Date.now()+timeout; while (!predicate()) { if (Date.now()>end) throw Error('Timed out waiting for serial state'); await delay(10); } }
const fresh = () => structuredClone(defaults);

test('0 starts, pauses, resumes; 1 returns to holding', () => {
  const router = new Router(); const config = fresh(); let state = 'holding';
  for (const [command,time,expected] of [['0',1000,'playing'],['0',2000,'paused'],['0',3000,'playing'],['1',3100,'holding'],['0',4000,'playing'],['0',5000,'paused'],['1',5100,'holding']]) {
    state = nextState(state,router.route(command,config,time)); assert.equal(state,expected);
  }
  assert.equal(router.route('1',config,5150),null);
  assert.equal(router.route('garbage',config,6000),null);
});
test('framing handles chunks, CRLF, overflow and binary junk', () => {
  const f = new Framer(); assert.deepEqual(f.feed(Buffer.from('STA')),[]);
  assert.deepEqual(f.feed(Buffer.from('RT\r\n0\n1')),['START','0']);
  assert.deepEqual(f.feed(Buffer.from('\n')),['1']);
  assert.deepEqual(f.feed(Buffer.from('x'.repeat(300)+'0\n1\n')),['1']);
  assert.deepEqual(f.feed(Buffer.from([255,10,48,10])),['0']);
  assert.deepEqual(new Framer('byte').feed(Buffer.from('01\r\n')),['0','1']);
});
test('configuration rejects invalid settings without overwriting existing data', () => {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'touch-player-'));
  try {
    const c=saveConfig(root,fresh());
    assert.throws(()=>saveConfig(root,{...c,output:{...c.output,height:0}}));
    assert.deepEqual(readConfig(root),c);
    assert.throws(()=>normalize({...c,commands:{READY:'toggle'}}));
    assert.throws(()=>normalize({...c,serial:{...c.serial,framing:'byte',heartbeatTimeoutMs:5000}}));
    assert.throws(()=>normalize({...c,commands:{'0':'unknown'}}));
    assert.equal(normalize({serial:{port:'COM3'}}).serial.startupDelayMs,2000);
  } finally { fs.rmSync(root,{recursive:true,force:true}); }
});
test('media discovery uses natural sorting and skips hidden/non-video files', () => {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'touch-media-'));
  try {
    for (const f of ['10.mp4','2.MOV','.hidden.mp4','readme.txt']) fs.writeFileSync(path.join(root,f),'');
    assert.equal(path.basename(mediaFile(root,'.')),'2.MOV');
  } finally { fs.rmSync(root,{recursive:true,force:true}); }
});
test('USB identity follows the same board to a new COM number', () => {
  const a={path:'COM3',vendorId:'2341',productId:'0043',serialNumber:'A'};
  const b={...a,path:'COM9',serialNumber:'B'};
  const moved={...a,path:'COM10'};
  const config={port:'COM3',deviceIdentity:identity(a)};
  assert.equal(resolvePort(config,[b,moved]),moved);
  assert.equal(resolvePort(config,[b]),null);
  assert.equal(resolvePort(config,[moved,{...moved,path:'COM11'}]),null);
});
test('serial session filters boot input, handles READY, and keeps idle port open', async () => {
  const device='MOCK-READY'; SerialPortMock.binding.createPort(device);
  const session=new SerialSession(SerialPortMock,{interval:10});
  const received=[]; session.on('command',v=>received.push(v));
  const config={...defaults.serial,port:device,startupDelayMs:500};
  try {
    await session.start(config); await until(()=>session.phase==='settling');
    session.port.port.emitData('0\n0'); await delay(30); assert.deepEqual(received,[]);
    session.port.port.emitData('\nREADY\n'); await until(()=>session.phase==='connected');
    const port=session.port; session.configure({...config,debounceMs:250});
    await delay(50); assert.equal(session.port,port);
    const command=once(session,'command'); session.port.port.emitData('1\n'); assert.deepEqual(await command,['1']);
  } finally { await session.dispose(); }
});
test('manual stop cancels retry and stale input', async () => {
  const device='MOCK-STOP'; SerialPortMock.binding.createPort(device);
  const session=new SerialSession(SerialPortMock,{interval:10});
  try {
    await session.start({...defaults.serial,port:device,startupDelayMs:0}); await until(()=>session.phase==='connected');
    await session.stop(); await delay(150); assert.equal(session.phase,'disconnected'); assert.equal(session.port,null); assert.equal(session.desired,false);
  } finally { await session.dispose(); }
});
test('port error reconnects with a fresh parser and increasing retry policy', async () => {
  const device='MOCK-RECOVERY'; SerialPortMock.binding.createPort(device);
  const session=new SerialSession(SerialPortMock,{interval:10});
  const config={...defaults.serial,port:device,startupDelayMs:0,reconnectInitialDelayMs:100,reconnectMaxDelayMs:400};
  try {
    await session.start(config); await until(()=>session.phase==='connected');
    const old=session.port; old.port.emitData('0');
    old.emit('error',new Error('Cable unplugged'));
    await until(()=>session.phase==='connected' && session.port!==old);
    const received=[]; session.on('command',v=>received.push(v));
    session.port.port.emitData('\n1\n'); await until(()=>received.length===1); assert.deepEqual(received,['1']);
  } finally { await session.dispose(); }
});
test('optional heartbeat detects unresponsive firmware', async () => {
  const device='MOCK-HEARTBEAT'; SerialPortMock.binding.createPort(device);
  const session=new SerialSession(SerialPortMock,{interval:10});
  try {
    await session.start({...defaults.serial,port:device,startupDelayMs:0,heartbeatTimeoutMs:250,reconnectInitialDelayMs:500});
    await until(()=>session.phase==='connected'); await until(()=>session.phase==='waiting');
    assert.match(session.message,/heartbeat/);
  } finally { await session.dispose(); }
});
