"""Embedded in the controller Text DAT. Native TOPs/CHOPs do all media processing."""
import json
import time
from pathlib import Path

ACTIONS = {'toggle', 'reset', 'play', 'pause', 'restart'}
VIDEO_TYPES = {'.mp4', '.mov', '.m4v', '.avi', '.mpg', '.mpeg'}


class Player:
    def __init__(self, owner):
        self.owner = owner
        self.controls = owner.op('CONTROLS')
        self.root = Path(project.folder)
        self.state = 'holding'
        self.config = None
        self.last_command = None
        self.last_command_at = 0
        self.ready_at = 0
        self.last_poll = 0
        self.want_serial = False
        self.serial_status = 'Disconnected'
        self.start_frame = 0
        self.error = ''
        self.reload()

    def node(self, name):
        return self.owner.op(name)

    def status(self):
        self.controls.par.State = self.state.upper()
        self.controls.par.Serialstatus = self.serial_status
        self.controls.par.Message = self.error or '0: start / pause / resume    1: return to holding'

    def discover(self, folder):
        path = (self.root / folder).resolve()
        files = sorted((p for p in path.iterdir() if p.suffix.lower() in VIDEO_TYPES and not p.name.startswith('.')), key=lambda p: p.name.lower())
        if len(files) != 1:
            raise ValueError('Keep exactly one video in {} (found {}).'.format(path, len(files)))
        return files[0]

    def read_config(self):
        cfg = json.loads((self.root / 'config.json').read_text())
        o, s, v = cfg['output'], cfg['serial'], cfg['videos']
        for key in ['width', 'height']:
            if type(o[key]) is not int or not 1 <= o[key] <= 16384:
                raise ValueError('output.{} must be an integer from 1 to 16384'.format(key))
        if o['scale'] not in ['fit', 'fill', 'stretch']:
            raise ValueError('output.scale must be fit, fill, or stretch')
        if type(o['display']) is not int or o['display'] < 0:
            raise ValueError('output.display must be a nonnegative display number')
        if str(s['baudRate']) not in self.node('arduino_serial').par.baudrate.menuNames:
            raise ValueError('Unsupported serial.baudRate')
        if not isinstance(s['port'], str):
            raise ValueError('serial.port must be a string')
        if any(not isinstance(s[k], (int, float)) or s[k] < 0 for k in ['debounceMs', 'startupDelayMs']):
            raise ValueError('Serial timing values must be nonnegative')
        if not isinstance(cfg['commands'], dict) or not cfg['commands'] or any(not k or k.strip()!=k or '\n' in k or '\r' in k or action not in ACTIONS for k, action in cfg['commands'].items()):
            raise ValueError('commands must map single-line text to toggle, reset, play, pause, or restart')
        if v['endBehavior'] not in ['holding', 'freeze', 'close']:
            raise ValueError('videos.endBehavior must be holding, freeze, or close')
        if not 0 <= float(v['volume']) <= 1:
            raise ValueError('videos.volume must be 0 to 1')
        return cfg, self.discover(v['holdingFolder']), self.discover(v['playbackFolder'])

    def reload(self):
        try:
            cfg, holding, playback = self.read_config()
        except Exception as exc:
            self.error = str(exc)
            self.status()
            return False
        self.disconnect()
        self.config = cfg
        self.error = ''
        self.node('holding_video').par.file = str(holding)
        self.node('playback_video').par.file = str(playback)
        self.node('holding_video').par.reloadpulse.pulse()
        self.node('playback_video').par.reloadpulse.pulse()
        self.refresh_ports()
        p = self.controls.par
        p.Serialport = cfg['serial']['port'] or '__none__'
        p.Baudrate = str(cfg['serial']['baudRate'])
        p.Width = cfg['output']['width']
        p.Height = cfg['output']['height']
        p.Display = cfg['output']['display']
        p.Scale = cfg['output']['scale']
        p.Endbehavior = cfg['videos']['endBehavior']
        p.Volume = cfg['videos']['volume']
        p.Autoopen = cfg['output']['openOnLaunch']
        self.apply_output()
        self.reset()
        if cfg['serial']['autoConnect']:
            self.connect()
        self.status()
        return True

    def apply_output(self):
        p = self.controls.par
        for name in ['holding_fit', 'playback_fit']:
            n = self.node(name)
            n.par.resolutionw = int(p.Width)
            n.par.resolutionh = int(p.Height)
            n.par.fit = {'fit': 'fitbest', 'fill': 'fitoutside', 'stretch': 'fill'}[p.Scale.eval()]
        panel = self.node('screen')
        panel.par.w = int(p.Width)
        panel.par.h = int(p.Height)
        w = self.node('output_window')
        w.par.display = int(p.Display)

    def save_settings(self):
        if self.config is None:
            self.error = 'Correct config.json and reload before saving.'
            self.status()
            return
        p = self.controls.par
        cfg = json.loads(json.dumps(self.config))
        cfg['serial'].update(port='' if p.Serialport.eval() == '__none__' else p.Serialport.eval(), baudRate=int(p.Baudrate.eval()))
        cfg['output'].update(width=int(p.Width), height=int(p.Height), display=int(p.Display), scale=p.Scale.eval(), openOnLaunch=bool(p.Autoopen))
        cfg['videos'].update(endBehavior=p.Endbehavior.eval(), volume=float(p.Volume))
        path = self.root / 'config.json'
        temp = path.with_suffix('.json.tmp')
        temp.write_text(json.dumps(cfg, indent=2) + '\n')
        temp.replace(path)
        self.reload()

    def refresh_ports(self):
        port = self.controls.par.Serialport.eval()
        available = list(self.node('arduino_serial').par.port.menuNames or [])
        configured = self.config['serial']['port'] if self.config else ''
        for extra in [configured, port]:
            if extra and extra != '__none__' and extra not in available:
                available.append(extra)
        p = self.controls.par.Serialport
        p.menuNames = ['__none__'] + available
        p.menuLabels = ['Select Arduino port'] + available
        if port in p.menuNames:
            p.val = port

    def connect(self):
        if self.config is None:
            return
        s = self.node('arduino_serial')
        s.par.active = False
        port = self.controls.par.Serialport.eval()
        self.want_serial = bool(port and port != '__none__')
        if not self.want_serial:
            self.serial_status = 'Select Arduino port, then Connect'
        else:
            s.par.port = port
            s.par.baudrate = self.controls.par.Baudrate.eval()
            s.par.clear.pulse()
            self.last_command = None
            self.ready_at = time.monotonic() + self.config['serial']['startupDelayMs'] / 1000
            s.par.active = True
            self.serial_status = 'Opening / waiting for Arduino'
        self.status()

    def disconnect(self):
        self.want_serial = False
        self.node('arduino_serial').par.active = False
        self.serial_status = 'Disconnected'
        self.status()

    def receive(self, message):
        if self.config is None or not self.want_serial:
            return
        text = str(message).strip()
        if text == 'READY':
            self.ready_at = 0
            return
        if time.monotonic() < self.ready_at:
            return
        self.command(text)

    def command(self, text, debounce=True):
        if self.config is None:
            return
        action = self.config['commands'].get(str(text).strip())
        if action is None:
            return
        now = time.monotonic()
        if debounce and text == self.last_command and (now - self.last_command_at) * 1000 < self.config['serial']['debounceMs']:
            return
        self.last_command, self.last_command_at = text, now
        self.action(action)

    def action(self, action):
        if self.config is None:
            return
        if action == 'reset':
            self.reset()
        elif action == 'restart':
            self.start()
        elif action == 'toggle':
            if self.state in ['holding', 'ended']:
                self.start()
            elif self.state == 'playing':
                self.pause()
            else:
                self.resume()
        elif action == 'play':
            self.resume() if self.state == 'paused' else self.start() if self.state != 'playing' else None
        elif action == 'pause' and self.state == 'playing':
            self.pause()
        self.status()

    def start(self):
        movie = self.node('playback_video')
        movie.par.play = False
        movie.par.cuepulse.pulse()
        movie.cook(force=True)
        self.node('video_switch').par.index = 1
        movie.par.play = True
        self.state = 'playing'
        self.start_frame = absTime.frame
        self.status()

    def pause(self):
        self.node('playback_video').par.play = False
        self.state = 'paused'
        self.status()

    def resume(self):
        self.node('playback_video').par.play = True
        self.state = 'playing'
        self.status()

    def reset(self):
        self.node('video_switch').par.index = 0
        self.node('playback_video').par.play = False
        self.node('playback_video').par.cuepulse.pulse()
        self.node('holding_video').par.play = True
        self.state = 'holding'
        self.status()

    def open_output(self, fullscreen=True):
        self.apply_output()
        w = self.node('output_window')
        w.par.winclose.pulse()
        w.par.size = 'fill' if fullscreen else 'custom'
        w.par.borders = not fullscreen
        w.par.winw = 1000
        w.par.winh = max(100, round(1000 * int(self.controls.par.Height) / int(self.controls.par.Width)))
        w.par.cursorvisible = 'nocursor' if fullscreen else 'alwaysvisible'
        if fullscreen:
            w.par.performance.pulse()
        else:
            w.par.winopen.pulse()

    def close_output(self):
        self.node('output_window').par.winclose.pulse()
        ui.performMode = False

    def tick(self):
        if self.config is None:
            return
        if self.state == 'playing':
            self.node('playback_video').cook(force=True)
            info = self.node('playback_info')
            info.cook(force=True)
            if absTime.frame > self.start_frame + 3 and info['last_frame'] is not None and float(info['last_frame']) > 0:
                end = self.controls.par.Endbehavior.eval()
                if end == 'freeze':
                    self.node('playback_video').par.play = False
                    self.state = 'ended'
                    self.status()
                else:
                    self.reset()
                    if end == 'close':
                        self.close_output()
        now = time.monotonic()
        if now - self.last_poll < 2:
            return
        self.last_poll = now
        if self.want_serial:
            s = self.node('arduino_serial')
            if s.errors():
                self.serial_status = 'Waiting / retrying: ' + s.par.port.eval()
                s.par.active = False
                s.par.clear.pulse()
                self.last_command = None
                self.ready_at = now + self.config['serial']['startupDelayMs'] / 1000
                s.par.active = True
            else:
                self.serial_status = ('Arduino starting: ' if now < self.ready_at else 'Port open: ') + s.par.port.eval()
        self.status()


_player = None


def get():
    global _player
    if _player is None:
        _player = Player(me.parent())
    return _player


def startup():
    global _player
    _player = None
    player = get()
    if player.config and player.config['output']['openOnLaunch']:
        run("op(args[0]).module.get().open_output(True)", me.path, delayFrames=15)


def pulse(name):
    p = get()
    actions = {
        'Toggle': lambda: p.action('toggle'),
        'Reset': p.reset,
        'Fullscreen': lambda: p.open_output(True),
        'Preview': lambda: p.open_output(False),
        'Closeoutput': p.close_output,
        'Reload': p.reload,
        'Saveconfig': p.save_settings,
        'Connect': p.connect,
        'Disconnect': p.disconnect,
        'Refreshports': p.refresh_ports,
    }
    if name in actions:
        try:
            actions[name]()
        except Exception as exc:
            p.error = str(exc)
            p.status()
            raise
