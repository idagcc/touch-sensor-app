# Touch Player for Windows

Standalone Electron player for Windows 10/11, x64. Download the installer or portable ZIP from the repository's **Releases** page. Node.js and TouchDesigner are not needed to run the packaged app.

The macOS app remains the native Swift version in the repository root. This directory contains the Windows app and can also be run on macOS for development.

## Use

1. Install **TouchPlayer-Windows-Setup-1.3.0-x64.exe**, or extract the portable ZIP and open **Touch Player.exe**. Keep every file from the portable ZIP together.
2. Click **Video folders**. Replace the demo in `media/holding` and the demo in `media/playback`, keeping one video per folder. MP4/H.264 is a practical starting format; MOV/M4V support depends on their codecs.
3. Click **Reload media & JSON**.
4. Choose your Arduino's **COM** port and matching baud rate (default 9600). Close Arduino Serial Monitor, then click **Connect Arduino**. Wait for **Arduino connected**.
5. Set canvas dimensions, scaling and output display. Save settings and click **Launch full screen**.

| Input | Behavior |
| --- | --- |
| `0` | From holding: play. While playing: pause. While paused: resume. |
| `1` | Stop and rewind playback; return to the looping holding video. |
| Playback finishes | Return to holding by default. |

Keyboard **0** / **Space** and **1** / **R** do the same actions without an Arduino. **F** launches full screen; **Esc** returns to the panel. Shortcuts are ignored while editing fields. The manual **Restart video** button is also available. Closing the control panel quits the app; closing the output window returns to the panel while playback remains available.

## Videos and JSON

The active folder is printed at the bottom of the panel. By default it is under `%APPDATA%/Touch Player/Touch Player Data`. **Choose data folder** can select any folder containing `config.json` and `media`; that choice is remembered. For a portable installation, put **Touch Player Data** beside **Touch Player.exe** before first launch. A previously chosen data folder takes precedence and is always displayed in the panel.

```text
Touch Player Data/
  config.json
  media/holding/your-video.mp4
  media/playback/your-video.mp4
```

The JSON format matches the Mac player for command mappings, video folders, baud rate and timing. COM-port names, saved device identity and display IDs are platform-specific, so select those again on Windows. `output.width` / `height` set the canvas aspect ratio; configure the physical display resolution in Windows Display settings.

```json
"commands": {
  "0": "toggle",
  "1": "reset"
}
```

Send text lines from Arduino: `Serial.println("0");` or `Serial.println("1");`. Send once per gesture. Byte framing is available for `Serial.write('0')` / `Serial.write('1')`; binary `Serial.write(0)` is a different protocol and is ignored.

## Connection recovery

Serial communication runs in Electron's main process, independent of the video renderer. It uses exclusive port access, 8N1, bounded line parsing and a rate limit. Connections remain open while the sensor is idle. Retries use increasing delays; a saved USB serial number allows the same board to be followed when Windows changes its COM number. Ambiguous boards are not guessed. Boards without unique identity may need their port reselected.

The default 2-second startup window ignores boot traffic; `READY` ends it early. Heartbeat monitoring is off by default. With firmware sending `HEARTBEAT` every second, `serial.heartbeatTimeoutMs: 5000` detects stalled firmware. Both status words are reserved and use newline framing. Recovery also runs after sleep/wake; manual disconnect cancels retries. Playback continues through serial recovery. Physical cable/power faults and events sent while disconnected cannot be recovered reliably by the plain `0`/`1` protocol.

## Development and builds

Use Node.js 22.12 or later:

```sh
cd Windows
npm ci
npm test
npm run smoke
npm start
```

On Windows, `npm run dist:win` produces the x64 installer and portable ZIP in `release/`. The GitHub release workflow builds on a Windows runner, runs serial/configuration tests, and exercises actual video play/pause/resume/reset before packaging. The smoke test uses demo clips and no physical Arduino. USB driver compatibility and the final installation's displays/audio still need an on-site Windows check.

The installer is currently unsigned. No signing certificate or auto-update service is configured. Media and settings remain local; the app does not load remote web content. The renderer uses isolated, restricted IPC following [Electron's security guidance](https://www.electronjs.org/docs/latest/tutorial/security/).
