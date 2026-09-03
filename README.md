# Chrome Stage

A macOS utility that lets you flip between per-profile Google Chrome windows inside a single work area — **without replacing Chrome or breaking how it normally feels**.

If you separate your work by Chrome profile (one profile per client, one for your own company, one for research, and so on), you quickly end up with a pile of Chrome windows that clutter Mission Control, the Dock, and window switching. Chrome Stage wraps those existing Chrome windows from the outside so that only the active one is on screen at a time, and gives you a switcher that shows a human-readable name for each profile.

> **Status:** Phase 1 (AX-only Stage) is complete and in daily use. This is a personal tool built for a specific workflow; expect rough edges. See the [Roadmap](#roadmap).

## Design philosophy (the one thing that never changes)

Chrome Stage **does not replace Chrome**. It only wraps the real Chrome windows from the outside.

- Chrome windows stay real Chrome windows.
- At most one active Chrome window is shown on screen at a time (**Stage method**).
- Inactive windows are moved off-screen (**offscreen parking**).
- The app is responsible only for the switcher UI, the profile-name display, and window control.
- Other-process Chrome windows are controlled externally via the Accessibility API and CoreGraphics — never embedded into the app.

This is deliberately *not* the "physically stack every window at the same coordinates" approach (the [Stacker](https://github.com/rloechner/stacker) model). Keeping a single window on screen avoids compounded drop shadows and avoids having to move every hidden window in sync when you drag or resize, which keeps the experience light.

## Core concepts

- **Stage** — the current work area: its position, size, target display, the currently shown slot, and the overlay position.
- **Slot** — the logical unit for one Chrome profile window: a display name (e.g. the client's name), a window reference, and a state (`visible` / `parked` / `missing`).
- **Switching** — park the current slot's window off-screen → restore the target window into the stage rect → focus it → update the overlay.

## Features (Phase 1)

- Detects standard Chrome browser windows via `CGWindowListCopyWindowInfo` (DevTools, popups, and OAuth windows are excluded).
- Add the frontmost Chrome window as a slot and give it a manual name.
- Switch slots from the menu bar, the floating overlay palette, or a global hotkey.
- **Offscreen parking** of inactive windows (leaving 1px on screen to avoid macOS clamping the window back).
- **Floating overlay palette** (a non-activating `NSPanel` + SwiftUI) that lists slots, highlights the active one, and switches on click. Draggable; its position is remembered. On macOS 26 it uses the Liquid Glass look (`NSGlassEffectView`).
- Right-click an empty (missing) slot to reassign the frontmost Chrome window to it.
- Session persistence to `~/Library/Application Support/ChromeStage/session.json`.
- **Chrome relaunch recovery**: when Chrome restarts (e.g. "Relaunch to update"), the windows it restores are matched back to their slots and re-parked automatically.
- **Safety features** (see below): `Unpark All`, restore-on-quit, crash recovery, and display-change handling.
- Zero third-party dependencies. Global hotkeys use Carbon `RegisterEventHotKey` directly.

## Requirements

- macOS 26 (Tahoe) or later.
- Google Chrome.
- **Accessibility** permission (required — used to read/move/resize/raise Chrome windows).
- **Screen Recording** permission is *not* used (thumbnails are intentionally out of scope for now).
- Xcode 26+ to build.

## Build & run

```bash
# Build
xcodebuild -project app/ChromeStage.xcodeproj -scheme ChromeStage build

# Or open in Xcode and run
open app/ChromeStage.xcodeproj
```

There is also a headless self-test that exercises detection → AX matching → park → restore → persistence without launching the UI:

```bash
/path/to/ChromeStage.app/Contents/MacOS/ChromeStage --selftest
```

On first launch, macOS will ask for Accessibility permission. Grant it in **System Settings → Privacy & Security → Accessibility**, then the app will pick it up automatically.

Chrome Stage runs as a menu-bar app (`LSUIElement`) with no Dock icon; look for the icon in the menu bar.

## Usage

### Menu bar

Click the menu-bar icon to:

- See and switch to registered slots (the active one is checked).
- **Add the frontmost Chrome window as a slot…** and name it.
- Remove slots.
- Show/hide the overlay palette.
- **Unpark All Chrome Windows**.
- Quit (all parked windows are restored on quit).

### Overlay palette

- Click a chip to switch to that slot.
- Drag chips to reorder; drag the palette to move it (position is remembered).
- Right-click an empty slot to assign the frontmost Chrome window to it.

### Hotkeys (default)

| Action | Shortcut |
|---|---|
| Next slot | `Ctrl+Option+Tab` |
| Previous slot | `Ctrl+Option+Shift+Tab` |
| Jump to slot 1–9 | `Ctrl+Option+1` … `Ctrl+Option+9` |
| Unpark all windows | `Ctrl+Option+U` |

These are chosen not to collide with Chrome's own `Ctrl+Tab`.

## Safety features

Because offscreen parking can strand a window off-screen if something goes wrong, the following are always maintained:

- **Unpark All** — restore every window from the menu bar or hotkey.
- **Restore on quit** — all windows are restored when the app terminates (including on `SIGTERM`).
- **Crash recovery** — parked windows are detected and restored on the next launch.
- **Display-change handling** — parking coordinates are recomputed when the display configuration changes, and an off-screen stage rect is reset onto the main display.
- **Chrome-quit detection** — slots become `missing` when Chrome exits, remembering where each window was.
- **Chrome relaunch recovery** — when Chrome comes back and restores its windows, they are matched to slots by geometry (Chrome restores each window at its saved position, pulled into the work area) and re-parked. An ambiguous match is left as `missing` rather than guessed, so a window is never labelled with the wrong profile.

## Privacy

This tool is built to be used around confidential, client-separated browsing, so:

- URLs and page titles are never stored, sent, or logged.
- The persisted session file only contains things like the profile name and a window ID.
- Logging uses `OSLog` and never emits URLs or titles.
- Thumbnails (which would require Screen Recording) are disabled by default.

## Roadmap

The app automates profile-name detection in stages: manual mapping → reading Chrome's `Local State` → a companion Chrome extension + Native Messaging.

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | AX-only Stage: manual slot names, offscreen parking, overlay switcher, Unpark All | ✅ Complete |
| Phase 2 | Profile Registry: suggest profile names from Chrome's `Local State` | Planned |
| Phase 3 | Companion extension + Native Messaging: automatic profile recognition | Planned |
| Phase 4 | Polish: thumbnails, Raycast integration, richer overlay, etc. | Planned |

## Non-goals

- Building a browser, or re-implementing Chrome in a WebView.
- Replacing Chrome's profile management, session restore, or Dock menu.
- Truly embedding another process's Chrome window into an `NSView`.
- Keeping every Chrome window moving in sync (the pitfall of the Stacker model).

## Project structure

```
app/ChromeStage/          Swift / AppKit sources
  AppDelegate.swift         Menu-bar app entry point, menu, lifecycle
  StageController.swift     Stage/slot state, switching, parking, recovery
  WindowDiscoveryService    Chrome window detection (CGWindowList + bundle id)
  AXWindow.swift            Thin Accessibility-API wrapper (read/move/resize/raise)
  SlotModels.swift          Slot / session data models + JSON persistence
  OverlayPanel.swift        Floating overlay palette (NSPanel + SwiftUI)
  HotKeyController.swift     Global hotkeys via Carbon
  AccessibilityPermission   Permission check & prompt
  Selftest.swift            Headless --selftest mode
  Log.swift                 OSLog wrappers
spikes/                   Standalone verification experiments
```

## License

Released under the [MIT License](LICENSE).
