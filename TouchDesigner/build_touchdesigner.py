"""Run inside TouchDesigner's Textport to build the editable project."""
from pathlib import Path
import json

ROOT = Path(globals().get('TOUCH_PLAYER_FOLDER', project.folder))
# Save a separate project before changing the current network; never overwrite the source .toe.
project.save(str(ROOT / 'TouchSensorPlayer.toe'))
if op('/touch_player'):
    op('/touch_player').destroy()
b = op('/').create(baseCOMP, 'touch_player')
b.nodeX, b.nodeY = 0, 0


def node(kind, name, x, y, color=None):
    n = b.create(kind, name)
    n.nodeX, n.nodeY = x, y
    if color:
        n.color = color
    return n


c = node('baseCOMP', 'CONTROLS', -750, 350, (0.15, 0.6, 0.55))
c.nodeWidth, c.nodeHeight = 220, 130
page = c.appendCustomPage('Player')
for name, label in [('Toggle','0 · Start / Pause / Resume'), ('Reset','1 · Return to Holding'), ('Fullscreen','Open Full Screen'), ('Preview','Open Windowed Preview'), ('Closeoutput','Close Output'), ('Reload','Reload JSON + Videos')]:
    page.appendPulse(name, label=label)
for name, label in [('State','Playback State'), ('Serialstatus','Serial Status'), ('Message','Message')]:
    page.appendStr(name, label=label)[0].readOnly = True
page = c.appendCustomPage('Setup')
p = page.appendMenu('Serialport', label='Arduino Port')[0]
p.menuNames, p.menuLabels = ['__none__'], ['Select Arduino port']
p = page.appendMenu('Baudrate', label='Baud Rate')[0]
p.menuNames = ['1200','2400','9600','19200','38400','57600','115200','230400','460800','921600','1382400']
p.menuLabels = p.menuNames
p.val = '9600'
for name, label in [('Refreshports','Refresh Ports'), ('Connect','Connect Arduino'), ('Disconnect','Disconnect Arduino')]:
    page.appendPulse(name, label=label)
for name, label, value in [('Width','Canvas Width',2560),('Height','Canvas Height',1280),('Display','Output Display (0 = first)',0)]:
    p = page.appendInt(name, label=label)[0]
    p.val = value
    p.min = 0 if name == 'Display' else 1
    p.clampMin = True
p = page.appendMenu('Scale', label='Video Scaling')[0]
p.menuNames, p.menuLabels = ['fit','fill','stretch'], ['Fit · black bars','Fill · crop','Stretch']
p = page.appendMenu('Endbehavior', label='When Playback Ends')[0]
p.menuNames, p.menuLabels = ['holding','freeze','close'], ['Return to holding','Freeze last frame','Close output window']
p = page.appendFloat('Volume', label='Playback Volume')[0]
p.val, p.min, p.max, p.clampMin, p.clampMax = 1, 0, 1, True, True
page.appendToggle('Autoopen', label='Open Full Screen on Launch')
page.appendPulse('Saveconfig', label='Save Settings to JSON + Apply')

holding = node('moviefileinTOP', 'holding_video', -500, 120)
playback = node('moviefileinTOP', 'playback_video', -500, -120)
for n in [holding, playback]:
    n.par.playmode = 'sequential'
    n.par.cuepoint = 0
    n.par.cuepointunit = 'fraction'
    n.par.alwaysloadinitial = True
    n.par.play = n == holding
    n.viewer = True
playback.par.textendleft = 'hold'
playback.par.textendright = 'hold'
holding.par.textendright = 'cycle'
for movie, name, y in [(holding,'holding_fit',120),(playback,'playback_fit',-120)]:
    f = node('fitTOP', name, -240, y)
    f.inputConnectors[0].connect(movie)
    f.par.outputresolution = 'custom'
    f.par.resolutionw, f.par.resolutionh = 2560, 1280
    f.par.fit = 'fitbest'
    f.par.bgcolora = 1
    f.viewer = True
switch = node('switchTOP', 'video_switch', 10, 100)
switch.inputConnectors[0].connect(b.op('holding_fit'))
switch.inputConnectors[1].connect(b.op('playback_fit'))
switch.par.index = 0
out = node('nullTOP', 'OUT_VIDEO', 250, 100, (0.15,0.6,0.55))
out.inputConnectors[0].connect(switch)
out.viewer = True
panel = node('containerCOMP', 'screen', 490, 100)
panel.par.w, panel.par.h = 2560, 1280
panel.par.top = 'OUT_VIDEO'
panel.par.topfill = 'best'
panel.par.bgalpha = 1
window = node('windowCOMP', 'output_window', 730, 100, (0.15,0.6,0.55))
window.par.winop = 'screen'
window.par.title = 'Touch Player · 2560 × 1280'
window.par.size = 'fill'
window.par.dpiscaling = 'native'
window.par.borders = False
window.par.cursorvisible = 'nocursor'
window.par.blocksleep = True
window.par.closeescape = True
window.par.justifyh = 'center'
window.par.justifyv = 'center'
window.par.setperform.pulse()

info = node('infoCHOP', 'playback_info', -240, -350)
info.par.op = 'playback_video'
audio = node('audiomovieCHOP', 'playback_audio', 10, -160)
audio.par.moviefileintop = 'playback_video'
audio.par.play.expr = "op('playback_video').par.play"
audio.par.volume.expr = "op('CONTROLS').par.Volume if op('video_switch').par.index == 1 else 0"
audioout = node('audiodeviceoutCHOP', 'AUDIO_OUT', 250, -160)
audioout.inputConnectors[0].connect(audio)

serial = node('serialDAT', 'arduino_serial', -750, -610)
serial.par.active = False
serial.par.format = 'perline'
serial.par.stopbits = '1'
serial.par.databits = '8'
serial.par.parity = 'none'
serial.par.maxlines = 30
serial.par.callbacks.eval().text = '''def onReceive(dat, rowIndex, message, bytes):
    op('controller').module.get().receive(message)
    return
'''
serial.par.callbacks.eval().nodeX, serial.par.callbacks.eval().nodeY = -500,-610
controller = node('textDAT', 'controller', -240, -610)
controller.text = (ROOT / 'controller.py').read_text()
control_exec = node('parameterexecuteDAT', 'control_buttons', 10,-610)
control_exec.par.op = 'CONTROLS'
control_exec.par.pars = '*'
control_exec.par.valuechange = False
control_exec.par.onpulse = True
control_exec.text = '''def onPulse(par):
    op('controller').module.pulse(par.name)
    return
'''
execute = node('executeDAT', 'startup_and_end_check', 250,-610)
execute.par.start = True
execute.par.framestart = True
execute.text = '''def onStart():
    op('controller').module.startup()
    return

def onFrameStart(frame):
    op('controller').module.get().tick()
    return
'''
keyboard = node('keyboardinDAT', 'keyboard_test', 490,-610)
keyboard.par.keys = '0 1'
keyboard.par.perform = True
keyboard.par.callbacks.eval().text = '''def onKey(dat, key, character, alt, lAlt, rAlt, ctrl, lCtrl, rCtrl, shift, lShift, rShift, state, time, cmd, lCmd, rCmd):
    if state and not (alt or ctrl or cmd):
        op('controller').module.get().command(character)
    return
'''
keyboard.par.callbacks.eval().nodeX, keyboard.par.callbacks.eval().nodeY = 730,-610
readme = node('textDAT','READ_ME',-500,350,(0.15,0.6,0.55))
readme.text = '''TOUCH PLAYER   |   2560 x 1280

Select CONTROLS and use its Player / Setup parameter pages.
0 = start, pause, resume. 1 = reset to holding.

TOP route: two videos > individual Fit TOPs > Switch > OUT_VIDEO.
Screen panel preserves the canvas aspect ratio inside the output window.
Window is configured for native pixels, selected display, no border,
Escape to close, and no display sleep while open.

Put exactly one video in media/holding and one in media/playback.
Edit config.json or use CONTROLS > Setup > Save Settings.
Reload JSON + Videos after replacing files. Relative to the .toe folder.
Serial uses newline text at 9600 baud, 8-N-1. Close Arduino Serial Monitor.

F1 opens the configured Perform window. Escape returns to editing.
Use CONTROLS buttons to test while editing; 0/1 keys work in Perform mode.

All nodes and Python DATs are editable. Controller.py is embedded in the
controller DAT, so edit that DAT for runtime logic. See README.md.
'''
controller.module.startup()
# Retain the original network, disabled, in this separately saved project.
if op('/project1'):
    op('/project1').allowCooking = False
for pane in ui.panes:
    if pane.type == PaneType.NETWORKEDITOR:
        pane.owner = b
        pane.home()
c.current = True
c.selected = True
project.save(str(ROOT / 'TouchSensorPlayer.toe'))
b.save(str(ROOT / 'TouchSensorPlayer.tox'))
print('Touch Player built: ' + str(ROOT / 'TouchSensorPlayer.toe'))
