<p align="center">
  <img src="assets/logo.svg" alt="Claude Usage" width="480">
</p>

<p align="center">
  <strong>Your Claude Code quota, live in the menu bar.</strong><br>
  Reads straight from the <code>claude</code> CLI on your machine — no browser cookie, no login, no network calls beyond your own Anthropic account.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/single-swift%20file-22d3ee?style=flat-square" alt="single swift file">
  <img src="https://img.shields.io/badge/dependencies-zero-6366f1?style=flat-square" alt="zero dependencies">
  <img src="https://img.shields.io/badge/license-MIT-94a3b8?style=flat-square" alt="MIT license">
</p>

<p align="center">
  <img src="assets/screenshot-main.png" alt="Claude Usage popover and settings menu" width="480">
</p>

---

## What it does

Claude Code already knows your usage — `claude -p "/usage"` prints it. This app just polls that command every 60 seconds and shows the result as three progress bars in your menu bar:

- **Session (5 hour)** — resets on a rolling window
- **Weekly (7 day)** — all models combined
- **Weekly, current model** — just the model you're actively using

Click the menu bar icon, see your bars. That's the whole app.

No cookies, no OAuth flow of its own, no server. It shells out to the `claude` binary you already have installed and authenticated — same source of truth as the CLI's own `/usage` command.

- **Pick what shows next to the icon** — session, weekly, or weekly-per-model, from the gear menu. Only options `/usage` actually returned show up.
- **Threshold alerts** — set a percentage in the gear menu and get a system sound once your selected figure crosses it.
- **Clear failure state** — if `claude` isn't installed, isn't logged in, or there's no connection, the popover shows a retry screen instead of spinning forever, and the menu bar icon swaps to a warning triangle.
- **Checks for updates on its own** — polls this repo's GitHub releases on launch and hourly (toggle in the gear menu), and offers a one-click "Update & Restart" that runs `brew upgrade` and reopens the app for you.

<p align="center">
  <img src="assets/menubar-icon.png" alt="Claude Usage menu bar icon" height="24">
</p>
<p align="center">
  <img src="assets/screenshot-dark.png" alt="Claude Usage popover, dark mode" width="280">
  <img src="assets/screenshot-light.png" alt="Claude Usage popover, light mode" width="280">
</p>

## Install

### Homebrew (recommended)

```bash
brew install djalmaaraujo/tap/claude-usage-menubar
```

Installs `ClaudeUsage.app` straight into `/Applications` and clears the quarantine flag, so it opens without a Gatekeeper warning.

### Build from source

```bash
git clone https://github.com/djalmaaraujo/claude-usage-menubar.git
cd claude-usage-menubar/app
./build.sh
```

Compiles, packages `ClaudeUsage.app`, ad-hoc signs it, and opens it. Drag `build/ClaudeUsage.app` into `/Applications` to keep it around.

### Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`) — for `swiftc`
- [Claude Code CLI](https://claude.com/claude-code) installed and logged in (`claude` on your `PATH`)

No other dependencies — one Swift file, SwiftUI + AppKit only.

## How it works

```
┌────────────────────────────┐
│  MenuBarExtra (SwiftUI)    │
│                             │
│  every 60s ──► Process ────┼──► claude -p "/usage" --output-format json
│                             │           │
│  regex-parse "result" ◄────┼───────────┘
│  → 3 progress bars          │
└────────────────────────────┘
```

`/usage` is a built-in Claude Code command answered locally by the CLI (no model call, no token cost — `total_cost_usd` and `duration_api_ms` come back `0`). The app just automates typing it every minute and turns the text reply into bars.

## Project layout

| File | Purpose |
|------|---------|
| `app/App.swift` | the entire app — menu bar scene, usage polling, parsing, UI |
| `app/make_icon.swift` | generates `AppIcon.icns` + `menubar-mark.png` from the Claude Code mark |
| `app/Info.plist` | bundle metadata, `LSUIElement` to hide the Dock icon |
| `app/build.sh` | compiles and packages `ClaudeUsage.app` |

## License

MIT © Djalma Araújo
