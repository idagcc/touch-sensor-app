# Touch Player

Download macOS and Windows builds from **[GitHub Releases](https://github.com/idagcc/touch-sensor-app/releases/latest)**. The native macOS source is in `Sources/`; the standalone Windows app is in [`Windows/`](Windows/README.md). The optional editable TouchDesigner project is in [`TouchDesigner/`](TouchDesigner/README.md).

A native macOS app for an Arduino-controlled, two-video installation. Runs on Apple Silicon and Intel Macs with macOS 13 or later. No browser, internet connection, or extra runtime required. `dist/TouchPlayer-macOS.zip` contains the app, data folder, instructions, and Arduino sketch for moving to another Mac.

## Start

1. Open **dist/Touch Player.app**. On first launch, confirm the **Touch Player Data** folder in the folder picker. This gives macOS permission to read your videos and settings.
2. Click **Video folders**. Replace the demo in `media/holding` with your holding video and the demo in `media/playback` with your main video. Keep one video in each folder; names can be anything.
3. Click **Reload media & JSON**. The holding video loops automatically.
4. Plug in the Arduino, select its serial port, choose the matching baud rate, and click **Connect Arduino**. Close the Arduino IDE's Serial Monitor first.
5. Enter your canvas width and height, choose the output display and scaling, and click **Save settings**. Click **Launch full screen**.

**0** or **Space** starts the playback video from holding, pauses it on the next press, and resumes it on another press. **1** or **R** stops and rewinds playback and returns to the holding video, including when paused. The next **0** starts the playback video from the beginning. **F** opens full screen; **Esc** returns to the control panel while playback and serial communication continue; **⌘Q** quits. Shortcuts are disabled while editing a text field. Closing the output window returns its preview to the panel. Closing the control panel quits the app. Keyboard testing works without an Arduino.

The app prevents display sleep while it runs. Other macOS notifications are controlled by your macOS Focus settings.

## Default Arduino commands

| Gesture | Serial text | Action |
| --- | --- | --- |
| Single palm touch | `0` | First touch starts playback; the next pauses it; another resumes from the same position. |
| Return / double tap | `1` | Stop and rewind playback, then return to the holding video. Works while playing or paused. The next `0` starts playback from the beginning. |

The default JSON mapping is:

```json
"commands": {
  "0": "toggle",
  "1": "reset"
}
```

By default, the main video plays once and returns to holding. Choose **Freeze last frame** or **Quit app** under **At end** if preferred. Reset always rewinds the main video. Holding video audio is muted by default; playback audio is enabled.

The Arduino classifies the gesture and sends newline-terminated text: `Serial.println("0");` for one single touch or `Serial.println("1");` for one double tap. Emit exactly one command per detected gesture; a double tap sends only `1`. Wait for the double-tap detection window before emitting a single-touch command. The macOS app acts on these classified commands immediately. CR, LF, and CRLF are accepted, including commands split across serial reads. Unknown lines are ignored. `Arduino/TouchButtons/TouchButtons.ino` provides two test buttons on pins 2 and 3 to GND, with internal pullups and press-edge debouncing; these buttons simulate single-touch and double-tap commands. Connect your actual sensor through its own gesture-detection firmware.

The app ignores consecutive identical commands within 180 ms. The Arduino should send **once per press/touch**, rather than continuously while held. Change `serial.debounceMs` if necessary. The serial connection uses 8 data bits, no parity, one stop bit, and no flow control.

## Data folder and JSON

Keep these together when moving the application:

```text
dist/
├── Touch Player.app
└── Touch Player Data/
    ├── config.json
    └── media/
        ├── holding/
        │   └── your-holding-video.mp4
        └── playback/
            └── your-playback-video.mp4
```

The path shown at the bottom of the control panel is the active data folder. **Choose data folder** selects another folder and remembers it for future launches. It also resolves a macOS file-access wait if a protected folder has not yet been authorized. If you move only the app on a new installation, it creates a starter data folder at `~/Library/Application Support/Touch Player`. It never edits files inside the app bundle. The development copy of `Touch Player Data` and the packaged copy in `dist` are separate.

The **Play / pause**, **Return to holding**, and optional **Restart** mappings can be changed in the control panel. The default is `0` for play/pause and `1` for return to holding. Restarting playback directly has no serial command by default. **Edit config.json** reveals the file in Finder for advanced editing. After an external edit, click **Reload media & JSON**. Saving settings or reloading resets the video to holding. Do not save in the panel before reloading external JSON edits, because the panel saves its current settings.

Example mappings:

```json
"commands": {
  "START": "play",
  "BUTTON_A": "toggle",
  "HOME": "reset",
  "AGAIN": "restart",
  "STOP": "pause"
}
```

Available actions: `play`, `toggle`, `pause`, `reset`, `restart`, `quit`. Multiple commands may map to the same action. The control panel shows the first command alphabetically for toggle/restart/reset; other aliases are preserved. `restart` rewinds the main video and starts playing; `reset` returns to the holding video.

Use `"framing": "byte"` for an Arduino using `Serial.write('1')` without a newline. Byte mode accepts single printable ASCII commands. The default `"newline"` mode supports longer command strings. Do not use `Serial.write(1)` for the text command `"1"`: that sends binary byte 0x01.

`serial.port` is a macOS device path such as `/dev/cu.usbmodem1101` (macOS uses device paths instead of Windows COM numbers). With `autoConnect` enabled, the app recovers after unplug/replug or Mac sleep. It remembers the selected board's USB identity, follows that same board if its device path changes, and saves the recovered path. Boards with a unique USB serial number can move between USB sockets; boards without one must use the same USB socket. The app does not guess between ambiguous matches or connect to a different board just because it has the same model number. To intentionally replace the board, select its current port and click **Connect Arduino**. Legacy drivers without USB identity information reconnect only to their saved path. Supported baud rates: 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400.

## Serial reliability

The app uses native Swift/AppKit and macOS serial APIs. One connection owns the port exclusively, with reads, device discovery, boot timing and recovery handled on background queues. The port stays open while the sensor is idle. Serial recovery does not stop or reset video playback. Changing command mappings, debounce, resolution, or video settings does not reopen the port. A manual disconnect cancels all automatic recovery until you connect again.

The app tolerates split lines, CR/LF/CRLF, unknown text, interrupted commands, and connection churn. Partial and queued commands from an old connection are discarded when a new connection starts. Frames and pending delivery queues are bounded; excessive serial traffic causes a controlled disconnect and retry instead of unlimited memory growth or delayed gesture playback. Firmware should send one event per gesture. Gesture delivery while the USB cable is disconnected is not guaranteed; the plain `0`/`1` protocol has no acknowledgement/replay mechanism.

These optional `serial` JSON fields have defaults when omitted, so older configuration files remain readable:

```json
"startupDelayMs": 2000,
"reconnectInitialDelayMs": 500,
"reconnectMaxDelayMs": 10000,
"heartbeatTimeoutMs": 0
```

After opening a port, the panel shows **Arduino starting**. Commands are accepted after `startupDelayMs`, or earlier if newline firmware sends `READY`. Startup traffic is discarded to prevent boot messages being mistaken for touches. Some Arduino boards [reset when their serial port opens](https://support.arduino.cc/hc/en-us/articles/4839084114460-If-your-board-runs-the-sketch-twice). Keep the connection open and wait for **Arduino connected** before testing the sensor.

Failed open/recovery attempts use increasing delays from 0.5 seconds up to 10 seconds. The delay resets after a stable connection. A missing board is waited for quietly. The panel distinguishes connecting, booting, connected, waiting/reconnecting, suspended and manually disconnected states, with details in **Serial activity**. Duplicate/unknown input logs are throttled.

`heartbeatTimeoutMs: 0` disables heartbeat supervision, allowing an idle board to remain connected indefinitely. For firmware that sends `Serial.println("HEARTBEAT");` every second, set `heartbeatTimeoutMs` to `5000` to recover if the firmware stops responding despite USB remaining attached. `READY` and `HEARTBEAT` are reserved status lines and require newline framing. They never trigger playback. The included two-button sketch sends both. Keep heartbeat supervision off for firmware that only sends touch commands.

Use a reliable data-capable USB cable and stable power. Keep [Arduino Serial Monitor and other port users closed](https://support.arduino.cc/hc/en-us/articles/4401874331410--Error-avrdude-when-uploading). Physical USB/power failures cannot be prevented by the app; recovery and on-site validation are still necessary.

`output.width` and `output.height` define the video canvas in pixels; portrait, square, and wide formats are supported up to 16384 per dimension. They define the aspect ratio, rather than changing the macOS display mode. Set the physical screen's resolution in macOS Displays settings. Windowed output scales the canvas to fit the desktop. Full-screen output covers the selected monitor and fits the canvas inside it, with black outside the canvas if their aspect ratios differ.

`output.scale`: `fit` shows the whole video with black bars, `fill` crops the video to the canvas, and `stretch` distorts it to fill the canvas. `output.displayID: 0` selects the main display. Use the panel to select another connected display. Enable **Open full screen on launch** for unattended starts.

`videos.endBehavior`: `holding`, `freeze`, or `quit`. `videos.volume`: 0–1. `videos.muteHolding`: true/false. `holdingFolder` and `playbackFolder` can be relative to the data folder or absolute paths. MP4, MOV, and M4V files are discovered, with the first filename in natural sort order selected. H.264 MP4 is a practical starting format; decoding depends on the codec inside the file. Restart/reload after replacing files; files are not watched while playing.

## Build and verify

```sh
swift build
swift test
bash scripts/build-app.sh
```

Tests use real macOS pseudo-terminals to cover reconnect races, 100 rapid connect/disconnect requests, startup filtering and READY handshakes, quiet idle connections, optional heartbeat failure, manual cancellation, sleep/wake recovery, and reattachment on a changed path. Identity matching is tested against different and ambiguous boards. Other checks cover split commands, framing, debounce, playback transitions, media selection, and old/new JSON compatibility. Real Arduino/USB driver behavior and physical sleep/wake still require an installation check. `swift test` requires a full Xcode installation; with only Command Line Tools selected, use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

The build script creates a universal `.app` and copies starter data to `dist` only if that folder does not already exist. It preserves the packaged data folder on subsequent builds. The app is locally ad-hoc signed, not Developer ID notarized for public distribution. The bundled demos are original placeholders included so the app can be tried immediately.

Run from source with `swift run TouchPlayer`. An optional `--data-dir /absolute/path` argument chooses a different data folder.

For a Windows development build, run `npm ci`, `npm test`, and `npm run dist:win` inside `Windows/` on Windows. See the Windows guide for installer and portable ZIP details. Tagging a release as `v*` runs both native Mac and Windows build jobs and publishes their downloadable assets after checks pass. The workflow can also be started manually for test builds.

The holding loop uses Apple's [AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper). Real Arduino hardware and the installation's actual display still need an on-site check.
