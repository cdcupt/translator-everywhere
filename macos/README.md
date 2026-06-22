# Translator Everywhere — macOS app

A menu-bar agent (`LSUIElement` — no Dock icon, no main window) that captures a
screen region, OCRs it on-device, translates it, and saves to a local notebook.
This directory is the on-device half of the product (TECH §8); the backend lives
elsewhere and is strictly optional.

**Status: v1.0.0 — feature-complete.** Hotkey → drag a screen region → on-device
Vision OCR → translate (Google free / OpenAI) → result popup + clipboard →
auto-save to a searchable vocabulary notebook (export / summarize). Preferences
(in-app hotkey recorder, engine, account) + first-run onboarding. Optional
Google / Apple (web OAuth) sign-in syncs the notebook across Macs via the backend.
Distributed as a signed (+ notarized) `.dmg` via GitHub Releases.

## Requirements

- macOS 14.0+ (deployment target)
- Xcode 26.x (this repo was scaffolded with 26.5)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

The `.xcodeproj` is **generated** from `project.yml` and is git-ignored — never
edit it by hand. Regenerate it after pulling or after changing sources.

## Generate the project

```sh
cd macos
xcodegen generate
```

This produces `Translator Everywhere.xcodeproj`.

## Build (headless)

Xcode may be installed but not `xcode-select`'d. Override `DEVELOPER_DIR`
per-command (no `sudo` needed). Code signing is off for now (a later slice adds
it):

```sh
cd macos
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project "Translator Everywhere.xcodeproj" \
  -scheme "Translator Everywhere" \
  -configuration Debug \
  -derivedDataPath .build/dd \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The built app lands at:

```
.build/dd/Build/Products/Debug/Translator Everywhere.app
```

## Run

```sh
open ".build/dd/Build/Products/Debug/Translator Everywhere.app"
```

Look for the **译** glyph in the menu bar (there is no Dock icon by design).

## Layout

```
macos/
├── project.yml          # xcodegen spec (the source of truth; .xcodeproj is generated)
├── README.md
└── Sources/
    ├── App/             # TranslatorEverywhereApp (SwiftUI App) + AppDelegate (NSStatusItem + menu)
    ├── UI/              # ResultPanel; NotebookWindow / Preferences / Onboarding land here
    ├── Hotkey/          # HotkeyManager — global ⌃⌥Y shortcut
    ├── Capture/         # CaptureCoordinator (actor) + RegionCapturer
    ├── OCR/             # OCRService — Vision VNRecognizeText
    ├── Translate/       # Translator protocol + GoogleEngine / OpenAIEngine
    ├── Notebook/        # NotebookStore — SwiftData source of truth
    ├── Sync/            # SyncClient (actor) — §7 backend contract
    ├── Auth/            # AuthClient — Apple / Google sign-in
    ├── Keychain/        # KeychainStore — OpenAI key + JWTs
    ├── Permission/      # PermissionService — screen-capture gate
    └── Settings/        # SettingsStore — UserDefaults prefs
```

Folders map 1:1 to the TECH §8.1 module map. Slice-1 files are minimal,
compiling stubs marked with `TODO(slice: …)`.
