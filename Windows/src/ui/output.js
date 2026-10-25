const holding = document.getElementById('holdingVideo');
const playback = document.getElementById('playbackVideo');
const canvas = document.getElementById('canvas');
const missing = document.getElementById('missing');
let model, revision = -1, sequence = -1, intent = 0, reportedError = false;
function resize() {
  if (!model) return;
  const { width, height, scale } = model.config.output;
  const factor = Math.min(innerWidth/width, innerHeight/height);
  canvas.style.width = width*factor + 'px'; canvas.style.height = height*factor + 'px';
  for (const video of [holding, playback]) video.style.objectFit = scale === 'stretch' ? 'fill' : scale === 'fill' ? 'cover' : 'contain';
}
function fail(error) { if (!reportedError) { reportedError = true; window.player.error(error?.message || 'Unsupported video. Try an H.264 MP4.'); } }
async function render(next) {
  model = next; resize();
  if (revision !== model.revision) {
    revision = model.revision; reportedError = false;
    for (const [key, video] of [['holding',holding], ['playback',playback]]) {
      video.pause();
      if (model.files[key]) video.src = model.files[key].url + '?revision=' + revision;
      else video.removeAttribute('src');
      video.load();
    }
    holding.muted = model.config.videos.muteHolding;
    holding.volume = playback.volume = model.config.videos.volume;
    sequence = -1;
  }
  if (sequence === model.sequence) return;
  sequence = model.sequence;
  const token = ++intent;
  holding.hidden = model.state !== 'holding'; playback.hidden = model.state === 'holding';
  missing.hidden = !!model.files[model.state === 'holding' ? 'holding' : 'playback'];
  missing.textContent = 'Add a video to the ' + (model.state === 'holding' ? 'holding' : 'playback') + ' folder, then reload media.';
  try {
    if (model.state === 'holding') {
      playback.pause(); playback.currentTime = 0;
      if (model.files.holding) await holding.play();
    } else {
      holding.pause();
      if (model.state === 'paused') playback.pause();
      else if (model.state === 'finished') { playback.pause(); if (Number.isFinite(playback.duration)) playback.currentTime = Math.max(0,playback.duration-0.001); }
      else {
        if (model.lastAction === 'restart' || playback.ended) playback.currentTime = 0;
        await playback.play();
      }
    }
  } catch (error) { if (token === intent && error.name !== 'AbortError') fail(error); }
}
playback.addEventListener('ended', () => window.player.ended());
for (const video of [holding, playback]) video.addEventListener('error', () => fail(video.error));
window.addEventListener('resize', resize);
window.addEventListener('keydown', event => {
  if (event.repeat || event.ctrlKey || event.metaKey || event.altKey) return;
  const key = event.key.toLowerCase();
  if (key === '0' || key === ' ') { event.preventDefault(); window.player.action('toggle'); }
  else if (key === '1' || key === 'r') window.player.action('reset');
  else if (key === 'escape') window.player.hideOutput();
  else if (key === 'f') window.player.output(true);
});
setInterval(() => {
  const video = model?.state === 'holding' ? holding : playback;
  window.player.progress({ time: Number.isFinite(video.currentTime) ? video.currentTime : 0, duration: Number.isFinite(video.duration) ? video.duration : 0 });
},250);
window.touchPlayerSmokeSnapshot = () => ({ state: model?.state, playbackTime: playback.currentTime, playbackPaused: playback.paused, holdingPaused: holding.paused, duration: playback.duration });
window.player.subscribe(render);
window.player.model().then(render).then(() => window.player.ready());
