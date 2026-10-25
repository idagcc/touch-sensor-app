# Touch Player — TouchDesigner

Open **TouchSensorPlayer.toe** in TouchDesigner. The editable network is at `/touch_player`.

The canvas is configured for **2560 × 1280 (2:1)**. This Mac currently has a Non-Commercial key: TouchDesigner limits TOP resolution and renders this canvas at 1280 × 640. A license supporting full resolution is required for native 2560 × 1280. The output window can still fill the display for testing. See [Derivative's license limits](https://derivative.ca/UserGuide/TouchDesigner_Non-Commercial).

## Start

1. Replace the demo files with **exactly one video** in `media/holding` and **exactly one video** in `media/playback`. Filenames can be anything. MP4/H.264 is a good starting point; MOV and M4V are also accepted.
2. Select the green **CONTROLS** node. On its **Player** parameter page, press **Reload JSON + Videos**.
3. On **Setup**, choose **Arduino Port**, select the baud rate, and press **Connect Arduino**. macOS ports look like `/dev/cu.usbmodem…`; Windows ports look like `COM3`. Close Arduino Serial Monitor and any other app using that port.
4. Select **Output Display** (`0` is the first display), check width **2560** and height **1280**, then press **Save Settings to JSON + Apply**.
5. On **Player**, press **Open Full Screen**. **Escape** returns to editing. **Open Windowed Preview** opens a smaller test window.

**F1** also opens the configured Perform window. Keyboard **0** and **1** test the commands in Perform mode. While editing, use the CONTROLS pulse buttons so typing in a parameter does not accidentally change playback. Keep the main TouchDesigner timeline playing.

## Behavior

| Input | Result |
| --- | --- |
| `0` from holding | Start the playback video from the beginning |
| `0` while playing | Pause on the current frame |
| `0` while paused | Resume from that frame |
| `1` at any time | Return to looping holding video and rewind playback |
| Playback finishes | Return to holding, by default |

Holding audio is muted. The playback video's audio uses **playback_audio → AUDIO_OUT**. The included demo videos are silent. To choose an audio device, edit AUDIO_OUT.

**When Playback Ends** can instead freeze the final frame or close the output window. Closing the output returns to the TouchDesigner editor; it does not quit TouchDesigner. Reset always returns to holding.

## Files and configuration

Keep the `.toe`, `config.json`, and `media` folder together when moving this project:

```text
TouchDesigner/
  TouchSensorPlayer.toe
  TouchSensorPlayer.tox
  config.json
  media/
    holding/your-holding-video.mp4
    playback/your-playback-video.mp4
```

Edit `config.json` and press **Reload JSON + Videos**, or restart the project. Changing videos or reloading settings resets to holding. If JSON or the media selection is invalid, the Message field explains the issue and existing playback settings are retained. Use only one video per folder; hidden files are ignored.

The default command mapping is:

```json
"commands": {
  "0": "toggle",
  "1": "reset"
}
```

Supported actions are `toggle`, `reset`, `play`, `pause`, and `restart`. Commands can also be words such as `START`. Each command must arrive as a complete text line:

```cpp
Serial.begin(9600);
Serial.println("0");  // start / pause / resume
Serial.println("1");  // reset to holding
```

The connection uses **8 data bits, no parity, 1 stop bit**. Send one line per button press or detected touch. Do not send continuously while the sensor is held. `serial.debounceMs` suppresses consecutive duplicate commands within 180 ms. `serial.startupDelayMs` ignores boot traffic for 2 seconds after opening the port; a `READY` line ends this delay early. Unknown lines are ignored. The included Arduino sketch provides two debounced physical test buttons on pins 2 and 3, connected to GND.

The port dropdown refreshes with **Refresh Ports**. A configured port is retried every two seconds after TouchDesigner reports a serial error; if the board reappears under a different device path, select its new port. Actual USB hardware, device drivers, and unplug/replug recovery need a check with your Arduino.

`output.width` and `output.height` set the image canvas. They do not change the operating system's display resolution: configure the physical display for 2560 × 1280 in macOS Displays. `output.display` selects the TouchDesigner monitor number. Scaling options are **fit** (whole video with black bars), **fill** (crop to canvas), and **stretch**. The screen panel preserves the canvas's 2:1 ratio on other displays.

Set `output.openOnLaunch` to `true`, or enable **Open Full Screen on Launch** and save settings, for automatic full-screen startup. It is off in the delivered project so you can inspect and edit the nodes first. The Window COMP is borderless, uses native pixels, hides the cursor, and prevents display sleep while open. Escape closes it.

## Edit the nodes

| Node | Purpose |
| --- | --- |
| holding_video | Movie File In TOP, loops the holding video |
| playback_video | Movie File In TOP, holds its final frame for end detection |
| holding_fit / playback_fit | Separate editable Fit TOPs at the canvas resolution |
| video_switch | Input 0 = holding, input 1 = playback |
| OUT_VIDEO | Final TOP, available for any further compositing or output |
| screen | Container displaying OUT_VIDEO with the correct aspect ratio |
| output_window | Full-screen / windowed output, display and sleep settings |
| playback_info | Movie position, duration, and end-of-file information |
| playback_audio / AUDIO_OUT | Audio playback synchronized to the movie |
| arduino_serial / arduino_serial_callbacks | Native serial input and command forwarding |
| CONTROLS / control_buttons | Player and Setup parameter pages |
| controller | Editable Python state and configuration logic |
| startup_and_end_check | Startup loading and playback-end handling |
| keyboard_test / keyboard_test_callbacks | Keyboard 0/1 in Perform mode |

The Python is **embedded inside the DATs**. No pip installs or external Python runtime are needed to open the project. Edit the controller DAT to change runtime logic. `controller.py` is a source copy for rebuilding; changes to that external copy do not automatically reload into the project. Save the `.toe` after editing nodes. Reloading JSON reapplies configured media, canvas, and playback settings.

`TouchSensorPlayer.tox` is the reusable component. To use it in another project, put `config.json` and `media` beside that project's `.toe`, drop in the `.tox`, and press **Reload JSON + Videos**. Use the component's **Open Full Screen** button to set up its output.

The original project's `/project1` network is retained with cooking disabled in this new `.toe`; the original file on disk is unchanged. The player lives entirely inside `/touch_player`.

## Verification

`verification.json` records the in-TouchDesigner serial and playback checks using a local pseudo-serial port. They exercise the native Serial DAT, start/pause/resume/reset, incomplete lines, unknown commands, duplicate suppression, and playback-end return. Actual Arduino hardware was not connected during development. The supplied demo videos have no audio track; verify sound with your final media.
