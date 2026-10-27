# Yaosnap

A native macOS screenshot tool written in Swift and AppKit. No third party dependencies. Requires macOS 12 or later.

Yaosnap is a personal reimplementation of Snipaste 2, built to match the screenshot workflow I use every day. It does not reuse Snipaste code or binaries. Features are scoped by actual use, and the interaction model follows Snipaste closely.

## Features

**Capture**

- Multi-display frozen frame overlay, one window per screen
- Drag a selection in any direction with a live size readout
- Hover a window to highlight it, click to snap the whole window, drag to switch to a free selection
- Auto detect UI elements (buttons, rows) when accessibility permission is granted
- Nudge the selection with arrow keys, `Ctrl` to expand, `Shift` to shrink, or `WASD` while holding the mouse button
- Eight resize handles on the selection edge
- Fixed aspect ratios: free, 1:1, 4:3, 16:9, 16:10, 3:2
- Magnifier with `Alt`, color picker with `C`, `Shift` toggles Hex and rgb
- Active window capture, repeat last region, delayed capture (1 to 60 seconds)
- Whiteboard mode with a solid or transparent background
- Replay the last 10 captures with `,` and `.`, restored full screen at the original position

**Annotate**

- Fourteen tools: rectangle, rounded rectangle, ellipse, line, arrow, polyline, brush, marker, mosaic, blur, text, serial number, eraser, magnifier
- Palette with alpha, five pen widths, three line styles, remembered per tool
- Text with multiline editing, corner scaling, rotation, and four background modes
- Arrow with single, double, or reversed heads
- Undo and redo, plus a second pass select mode for moving, resizing, cloning, and multi-selecting shapes

**Output**

- Copy to clipboard with `Enter`, double click, or the toolbar
- Save panel with `⌘S`, quick save with `⇧` on the save button or `⌘⇧S`
- Copy as a PNG file with `⌥`
- Pin the selection to the screen with the middle mouse button or the toolbar button
- System share sheet, optional shadow margin
- Text recognition and QR or barcode scanning, results land in the clipboard

**Pin windows**

- `F3` pins the clipboard content as an always on top window. Images, colors, plain text, HTML, and image file paths all work
- Rotate, flip, scale, change opacity, switch to a thumbnail, reset with the middle mouse button
- Crop, grayscale, invert, four background modes
- Groups, solo mode, multi-select, mouse click-through
- Right click menu with copy image, save as, window shadow, scale presets, image processing, paste, move to group, close, and destroy
- Hover toolbar with zoom, rotate, flip, filters, copy, save, and close
- Annotate directly on a pin window with five tools and undo
- Close windows and step back through them with `,` and `.`, restoring the original position, size, and transform

**Command line**

```bash
snip                          # start a capture
snip --delay 3                # capture after 3 seconds
snip -o clipboard             # copy the latest capture
snip -o quick-save            # quick save the latest capture
snip -o ~/Desktop/a.png       # save the latest capture to a path
snip --pos 100 200            # pin the latest capture at a position
snip pick-color               # pick a pixel color and copy it
snip barcode-scan             # scan a barcode on screen
snip show-images              # show all pin windows
snip hide-images              # hide all pin windows
snip whiteboard --color red   # whiteboard mode
```

## Build

```bash
./build.sh
open Build/Yaosnap.app
```

The app runs as a menu bar item (`LSUIElement`) with no Dock icon. The build produces both `Build/Yaosnap.app` and the `snip` CLI at `.build/release/snip`.

Yaosnap runs as a self-signed app. It is not notarized and not distributed through the App Store.

## Permissions

Yaosnap needs **Screen Recording** permission:

1. Press `⌃⇧A` or click the menu bar icon and choose Capture. macOS prompts for access.
2. Open System Settings, Privacy and Security, Screen Recording, and enable Yaosnap.
3. Quit and relaunch Yaosnap. TCC applies the permission only on a fresh launch.

Auto detecting UI elements needs **Accessibility** permission. Everything else works without it.

## Default shortcuts

| Action | Shortcut |
| --- | --- |
| Capture | `⌃⇧A` |
| Pin clipboard | `F3` |
| Hide or show all pins | `⇧F3` |
| Toggle pin click-through | `⌃⇧T` |
| Capture active window | `⌃⇧W` |
| Repeat last region | `⌃⇧R` |
| Copy selection | `Enter` or double click |
| Save panel | `⌘S` |
| Quick save | `⇧` on save, or `⌘⇧S` |
| Cancel | `Esc` or right click |

All configurable shortcuts can be recorded in Settings. `F1`, `F2`, and the mute key are captured through a `CGEventTap` because Carbon hotkeys never receive events for keys owned by the window server. Other combinations use Carbon.

## Development

```bash
./build.sh                  # build app and CLI
./.env-tools/run-tests.sh   # unit tests
```

Unit tests use Swift Testing. The end to end suites live in `Tools/verify` and drive the real app on screen:

```bash
./Tools/verify/run-p1-e2e.sh
./Tools/verify/run-p2-annotate-e2e.sh
./Tools/verify/run-p3-pin-e2e.sh
./Tools/verify/run-cli-e2e.sh
./Tools/verify/run-settings-e2e.sh
```

The build script works with Command Line Tools only, no Xcode. It detects a local `.env-tools/swiftc-manifest` compatibility shim when present. `.env-tools/` is machine specific and gitignored.

## Project layout

- `Sources/YaosnapCore`: coordinate math, screen capture, window detection, annotation model and renderer, clipboard, hotkeys, settings, history. Unit testable.
- `Sources/Yaosnap`: AppKit shell with the menu bar, overlay windows, pin windows, settings, and annotation toolbar.
- `Sources/snip`: the `snip` command line parser and URL dispatcher.
- `Tests/YaosnapCoreTests`: unit tests.
- `Tools/verify`: end to end harnesses.
- `docs`: design notes and the Snipaste behavior checklist.

## Scope

Yaosnap targets macOS only. There is no license gate, no auto updater, no cloud OCR, and no localization.

## License

MIT. See [LICENSE](LICENSE).
