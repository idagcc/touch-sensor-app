const byId = id => document.getElementById(id);
let model, revision = -1, portsKey = '', displaysKey = '', previewKey = '';
const preview = byId('preview');
function option(select, value, text) { const o = document.createElement('option'); o.value = value; o.textContent = text; select.append(o); }
for (const baud of [1200,2400,4800,9600,19200,38400,57600,115200,230400]) option(byId('baud'), baud, baud);
function error(reason) { byId('error').textContent = reason?.message || String(reason); }
async function run(action) { byId('error').textContent = ''; try { return await action(); } catch (reason) { error(reason); } }
function render(next) {
  model = next;
  const phase = model.serial.phase;
  byId('connectionStatus').textContent = ({ connected:'● Arduino connected',settling:'◌ Arduino starting',connecting:'◌ Connecting Arduino',waiting:'◌ Waiting / reconnecting',suspended:'◌ Serial suspended',disconnected:'● Disconnected' })[phase];
  byId('connectionStatus').title = model.serial.message;
  byId('connect').textContent = phase === 'disconnected' ? 'Connect Arduino' : phase === 'connected' ? 'Disconnect' : 'Cancel connection';
  byId('state').textContent = model.state.toUpperCase();
  byId('headline').textContent = ({holding:'Ready for the next touch.', playing:'Playback in motion.',paused:'Paused. Ready when you are.',finished:'Playback complete.'})[model.state];
  const refresh = revision !== model.revision;
  const nextPorts = JSON.stringify([model.ports,model.config.serial.port]);
  if (portsKey !== nextPorts || refresh) {
    portsKey = nextPorts;
    const select = byId('port'); const selected = refresh ? model.config.serial.port : select.value;
    select.replaceChildren(); option(select,'','Select serial port…');
    const ports = [...model.ports];
    if (model.config.serial.port && !ports.some(p => p.path === model.config.serial.port)) ports.push({path:model.config.serial.port});
    for (const p of ports) option(select,p.path,(p.friendlyName || p.manufacturer) ? `${p.friendlyName || p.manufacturer} · ${p.path}` : p.path);
    select.value = [...select.options].some(o => o.value === selected) ? selected : model.config.serial.port;
  }
  const nextDisplays = JSON.stringify(model.displays);
  if (displaysKey !== nextDisplays || refresh) {
    displaysKey = nextDisplays; const select = byId('display'); select.replaceChildren(); option(select,0,'Main display');
    for (const d of model.displays) option(select,d.id,`${d.name} · ${d.width} × ${d.height}`);
    select.value = String(model.config.output.displayID);
  }
  if (refresh) {
    revision = model.revision;
    byId('baud').value = model.config.serial.baudRate;
    byId('autoConnect').checked = model.config.serial.autoConnect;
    byId('width').value = model.config.output.width; byId('height').value = model.config.output.height;
    byId('scale').value = model.config.output.scale; byId('end').value = model.config.videos.endBehavior;
    byId('startup').checked = model.config.output.openOnLaunch && model.config.output.fullscreenOnLaunch;
    byId('commands').value = JSON.stringify(model.config.commands,null,2);
  }
  const key = model.state === 'holding' ? 'holding' : 'playback';
  const file = model.files[key]; const nextKey = `${revision}/${key}/${file?.name}`;
  byId('previewMissing').hidden = !!file;
  byId('mediaName').textContent = file?.name || 'No video loaded';
  byId('dataPath').textContent = 'DATA FOLDER  ' + model.root;
  if (previewKey !== nextKey) { previewKey = nextKey; preview.pause(); if (file) { preview.src = file.url + '?revision=' + revision; preview.load(); } else preview.removeAttribute('src'); }
  preview.loop = key === 'holding'; preview.muted = true;
  const ratio = model.config.output.width/model.config.output.height;
  const host = byId('previewCanvas').parentElement;
  const width = Math.min(host.clientWidth,host.clientHeight*ratio);
  byId('previewCanvas').style.width = width + 'px'; byId('previewCanvas').style.height = width/ratio + 'px';
  preview.style.objectFit = model.config.output.scale === 'stretch' ? 'fill' : model.config.output.scale === 'fill' ? 'cover' : 'contain';
  if (file) {
    if (Number.isFinite(model.progress.time) && Math.abs(preview.currentTime-model.progress.time) > 0.45) { try { preview.currentTime = model.progress.time; } catch {} }
    if (model.state === 'playing' || model.state === 'holding') preview.play().catch(() => {}); else preview.pause();
  }
  const format = time => `${String(Math.floor(time/60)).padStart(2,'0')}:${String(Math.floor(time%60)).padStart(2,'0')}`;
  byId('time').textContent = `${format(model.progress.time)} / ${format(model.progress.duration)}`;
  const log = byId('log'); const text = model.logs.map(l => `${l.time}  ${l.message}`).join('\n');
  if (text !== log.textContent) { log.textContent = text; log.scrollTop = log.scrollHeight; }
}
function serialSettings() { return { port: byId('port').value, baudRate: Number(byId('baud').value), autoConnect: byId('autoConnect').checked }; }
async function save() {
  const config = structuredClone(model.config);
  Object.assign(config.serial,serialSettings());
  const selected = model.ports.find(p => p.path === config.serial.port);
  if (config.serial.port !== model.config.serial.port) delete config.serial.deviceIdentity;
  config.output.width = Number(byId('width').value); config.output.height = Number(byId('height').value);
  config.output.displayID = Number(byId('display').value); config.output.scale = byId('scale').value;
  config.output.openOnLaunch = config.output.fullscreenOnLaunch = byId('startup').checked;
  config.videos.endBehavior = byId('end').value; config.commands = JSON.parse(byId('commands').value);
  render(await window.player.save(config));
}
const clicks = {
  toggle:()=>window.player.action('toggle'), holding:()=>window.player.action('reset'), restart:()=>window.player.action('restart'),
  save, reload:async()=>render(await window.player.reload()), refresh:async()=>render(await window.player.refresh()),
  folders:()=>window.player.mediaFolder(), config:()=>window.player.configFile(), choose:async()=>render(await window.player.chooseFolder()),
  fullscreen:()=>window.player.output(true), windowed:()=>window.player.output(false), connect:()=>window.player.connection(serialSettings())
};
for (const [id, action] of Object.entries(clicks)) byId(id).addEventListener('click',()=>run(action));
window.addEventListener('keydown', event => {
  if (event.repeat || event.ctrlKey || event.metaKey || event.altKey || event.target.closest('input,select,textarea,[contenteditable=true]')) return;
  const key=event.key.toLowerCase();
  if (key==='0' || key===' ') { event.preventDefault(); run(()=>window.player.action('toggle')); }
  else if (key==='1' || key==='r') run(()=>window.player.action('reset'));
  else if (key==='f') run(()=>window.player.output(true));
  else if (key==='escape') run(()=>window.player.hideOutput());
});
window.addEventListener('resize',()=> { if (model) render(model); });
window.player.subscribe(render); window.player.model().then(render).catch(error);
