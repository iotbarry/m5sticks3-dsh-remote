# DeepSeek Harness Remote (M5StickC S3)

Turn an **M5StickC S3** into a physical remote for DeepSeek Harness (DSH).

- **USB HID keyboard** — no drivers, works out of the box
- **Front click / double click** → send, reject; **hold the side key** → talk; **tap it** → delete
- **The screen switches by itself** when DSH asks for approval — otherwise it just
  shows a name, with nothing else on screen
- **Drives DSH's own voice recorder**, so the transcript really lands in the editor
- **Antialiased UI** — Mincho headline, breathing status dot, ripple feedback

```
┌──────────────────────────────┐          ┌──────────────────────────────┐
│       M5StickC S3            │          │      DeepSeek Harness        │
│                              │          │      (Electron / Chromium)   │
│  ┌────────────────────────┐  │          │                              │
│  │      程序猿白瑞         │  │  USB HID │   ┌──────────────────────┐   │
│  │           ◉            │  │ ───────► │   │  composer / session   │   │
│  └────────────────────────┘  │ keystrokes│  └──────────────────────┘   │
│                              │          │                              │
│  front  click  -> Enter       │          │   ▲                          │
│  front  double -> Esc         │          │   │ Chromium DevTools proto  │
│  side  hold/rel -> Ctrl+Alt+R  │  USB CDC │   │ (reads the DOM to spot   │
│                              │ ◄─────── │   │  an approval prompt)     │
│                              │ ASK/IDLE │   │                          │
└──────────────────────────────┘          └──────────────────────────────┘
                    ▲                                    ▲
                    │ COMx                               │ 127.0.0.1:9222
              ┌─────┴────────────────────────────────────┴─────┐
              │        pc/dsh-cdp-bridge.ps1 (PowerShell)     │
              └───────────────────────────────────────────────┘
```

---

## Controls

| Action | Sends | Purpose |
|---|---|---|
| Front button, **one click** | `Enter` | send message / allow |
| Front button, **double click** | `Esc` | reject / cancel |
| Side button, **tap** | `Backspace` | **delete one character** |
| Side button, **hold ≥0.25 s** | `Ctrl+Alt+R` | **start** DSH voice recording |
| Side button, **release** | `Ctrl+Alt+R` | **stop** and transcribe |
| Side button, **long press** | hardware | ROM download mode (for flashing) |
| Side button, **double click** | hardware | power off |

A single click is decided after **280 ms** so it can be told apart from a double click.
On the side key, holding **250 ms** starts recording; letting go before that counts as a
tap and sends `Backspace`.

## Screen

```
idle                                    approval
                                        
        程 序 猿 白 瑞                     ╭───────╮      ╭───────╮
                                          │  确认  │      │  拒绝  │
                    ◉                     ╰───────╯      ╰───────╯
```

Green dot = ready, red = not connected. Pressing a key fills the chosen pill and
ripples a coloured ring outwards (voice is red).

DSH shows two kinds of prompts, both supported:

| Prompt | Buttons |
|---|---|
| permission request | 允许一次 / 拒绝 |
| plan review | 同意执行 / 要求修改 |

---

## Quick start

### 1. Firmware

```bash
pio run                                          # build (from the repo root)
pio run -t upload --upload-port COMx             # flash
```

Hold the side button until the green LED blinks to enter download mode.
After flashing, **power cycle** (double click = off, single click = on) — esptool's
reset alone always lands in download mode on the ESP32-S3.

The board enumerates as a HID keyboard **and** a CDC serial port.

### 2. PC side

```cmd
pc\launch-dsh-a11y.cmd
```

This restarts DSH with `--remote-debugging-port=9222`. DSH is Electron, and its web
content is completely invisible to Windows UI Automation (only a `Chrome Legacy
Window` placeholder is exposed), so the DevTools protocol is the only way in.

```powershell
powershell -ExecutionPolicy Bypass -File "pc\dsh-cdp-bridge.ps1"
```

> ⚠️ **`-ExecutionPolicy Bypass` is not optional.** The script is unsigned and Windows
> defaults to `RemoteSigned`, so a plain `& .\dsh-cdp-bridge.ps1` fails with
> "not digitally signed / cannot be loaded". See trap 9 below.

```
remote serial port : COM13
DSH debug port     : 9222

00:34:17  -> IDLE
```

Then: **hold the side key → speak → release to transcribe → front click to send.**

### Options

| Flag | Default | Meaning |
|---|---|---|
| `-Port` | auto | remote serial port (prefers `MI_01`, avoids the ROM's `MI_00/MI_02`) |
| `-CdpPort` | `9222` | DSH debug port |
| `-ConfirmJs` / `-RejectJs` | Chinese + English words | button matching patterns |
| `-Discover` | — | list the page's buttons without acting |

---

## Traps worth knowing

1. **Arduino-ESP32 `USBHIDKeyboard::press()` never sends modifiers.**
   `press()` turns a modifier into `k = 0`, and `pressRaw(0)` returns before
   `sendReport()`. Enter and letters take another branch, so the keyboard *looks*
   fine while every chord silently fails. Send modifiers with `pressRaw(0xE0)` /
   `pressRaw(0xE2)` instead.

2. **No global `USBCDC` when `ARDUINO_USB_MODE=1`.** HID needs mode 1, and that
   turns `Serial` into UART0. Declare your own instance — the constructor calls
   `tinyusb_enable_interface()`, which is all the registration needed.

3. **The M5StickC S3's right-side button is plain GPIO 12.** M5Unified reads this
   board's buttons through the PMIC (M5PM1, I2C 0x6E) and does not map that key, so
   `M5.BtnB` never fires. Read the pin directly and self-calibrate the idle level.

4. **Electron content is invisible to UI Automation**, and
   `--force-renderer-accessibility` does not help. Use the DevTools protocol.

5. **Debounce after the branch matches, not before.** The board emits a chord in
   ~0 ms while a human takes ~150 ms; debouncing up front lets the modifier
   keydowns eat the real key's slot.

6. **PowerShell 5.1 reads BOM-less `.ps1` as ANSI** — Chinese turns into parse
   errors. Keep the scripts ASCII-only and match Chinese with `\uXXXX` escapes.

7. **`rst:0x15 (USB_UART_CHIP_RESET)` always boots into download mode**, so a real
   power cycle is required after flashing.

8. **Stop the bridge before flashing** — it holds the serial port and esptool then
   fails with `OSError 22`.

9. **Windows execution policy blocks the unsigned `.ps1`.** The default `RemoteSigned`
   rejects scripts it considers remote, and a file can be treated as remote even
   **without** a `Zone.Identifier` mark — for example on a non-system or synced drive.
   Fixes, in order of preference:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "pc\dsh-cdp-bridge.ps1"   # this call only
   Unblock-File .\pc\dsh-cdp-bridge.ps1                               # this file only
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force  # this process only
   ```

   Do **not** use `Set-ExecutionPolicy LocalMachine Unrestricted` — it weakens the
   whole machine for no good reason.

---

## Layout

```
m5sticks3_usbkbd/
├── platformio.ini          PlatformIO project
├── partitions.csv          nvs + 3 MB app
├── src/main.cpp            all firmware logic (~320 lines)
└── pc/
    ├── launch-dsh-a11y.cmd starts DSH with the debug port
    └── dsh-cdp-bridge.ps1  the bridge
```

## Known limits

- Voice goes through **DSH's own recorder**; Windows dictation does not work because
  DSH uses a Lexical editor, and text injected from outside never reaches its state.
- Single click costs **280 ms** so it can be separated from a double click.
- The side key must be held **250 ms** before recording starts, and recording ends the
  moment you let go — so do not rush the first word.
- A quick **tap** on the side key sends `Backspace`; only a **hold** starts recording.
- The bridge must be running for automatic view switching and key forwarding. The
  remote still types without it — the screen just stays on the name.
- Restart the bridge after restarting DSH (it reinstalls its in-page key mapping).

## License

Not specified. Check that your use is compatible with DeepSeek Harness's terms.
