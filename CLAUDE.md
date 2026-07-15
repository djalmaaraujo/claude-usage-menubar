# Release checklist

This app ships via a Homebrew cask in a **separate repo**:
`git@github.com:djalmaaraujo/homebrew-tap.git`, file `Casks/claude-usage-menubar.rb`.

A GitHub release in *this* repo is not enough on its own — the cask pins an
exact `version` + `sha256`, so it silently keeps serving the old build until
that file is updated too. Every release needs both halves:

1. Bump the version **in `app/Info.plist`'s `CFBundleShortVersionString`** (the
   update checker compares this against the GitHub release tag - if it's
   stale, "Check for Updates" always thinks it's out of date or never
   detects a real update). Then build clean and zip:
   ```bash
   cd app
   ./build.sh
   cd build
   ditto -c -k --sequesterRsrc --keepParent ClaudeUsage.app ClaudeUsage.app.zip
   shasum -a 256 ClaudeUsage.app.zip
   ```
2. Tag + push, then create the GitHub release with that zip attached:
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   gh release create vX.Y.Z app/build/ClaudeUsage.app.zip --title vX.Y.Z --notes "..."
   ```
3. **Update the tap** — clone/pull `homebrew-tap`, edit `Casks/claude-usage-menubar.rb`:
   `version` and `sha256` to match what you just built. Commit + push there too.
4. Verify end-to-end before calling it done:
   ```bash
   brew tap djalmaaraujo/tap   # or: brew untap then re-tap if already tapped, to bust cache
   brew upgrade --cask djalmaaraujo/tap/claude-usage-menubar
   ```
   Confirm it reports the new version and actually installs.

Skipping step 3 is the most likely mistake — the GitHub release succeeding
gives no signal that the tap is still stale.

## Gotchas learned the hard way

- **`MenuBarExtra(title:systemImage:)` silently drops the title text** under
  `.menuBarExtraStyle(.window)` - only the icon renders. Build the label as
  an explicit `HStack { Image; Text }` instead.
- **Never apply `.resizable()`/`.frame()` to an `Image(nsImage:)` inside a
  `MenuBarExtra` label** - it renders nothing at all (needs an intrinsic
  size before the status item's own layout pass, which `.resizable()`
  removes). Set `NSImage.size` directly instead and let it size itself.
  All menu bar icon variants (idle/alert/100%) must share the exact same
  `NSImage.size` box, or the status item visibly resizes ("flicks") when
  swapping between them.
- **`TextField`/`Slider` don't work inside a SwiftUI `Menu`** (NSMenu-backed
  items can't take keyboard/drag focus - they render but are inert). Any
  interactive control beyond `Toggle`/`Picker`/`Button` has to live in the
  main popover body, not the gear menu.
- **Read a `Process`'s stdout pipe before calling `waitUntilExit()`**, not
  after - if the child fills the pipe buffer before you drain it, both
  sides deadlock (child blocked writing, you blocked waiting).
- **`claude` triggers spurious macOS permission prompts** (Photos,
  Downloads, Desktop, network volume) when spawned from a GUI app unless
  run with `--safe-mode` *and* an explicit `currentDirectoryURL` pinned to
  `$HOME` - a GUI app's default cwd isn't `$HOME` the way Terminal's is,
  and claude's environment probing falls back to scanning common folders.
- **`brew upgrade` no-ops silently** if the local tap clone hasn't been
  refreshed - always `brew update` first, or it just re-opens the same
  (old) build.
- **`brew upgrade --cask` replaces the running app's own executable on
  disk** - macOS can kill a process whose backing file changes mid-run, so
  "upgrade then reopen" logic can't assume the app's own Swift code survives
  to run the reopen step. Hand the whole `brew upgrade; open ...` sequence
  to one detached shell process *before* asking the app to quit.
- **GitHub's unauthenticated API rate limit (60 req/hr per IP) is easy to
  exhaust during dev/testing** - the update checker hits it purely from
  repeated manual "Check for Updates" clicks during a single work session.
- **`/usage`'s CLI text output isn't stable-shaped** - e.g. the per-model
  weekly line omits its "resets ..." suffix when at 0% (right after a
  weekly reset), since it'd just repeat the "all models" line above it.
  Parsing regexes need optional groups with fallbacks, not fixed structure.
- **`/usage` itself costs zero tokens** (`total_cost_usd`/`duration_api_ms`
  come back `0`) - it's intercepted client-side, never reaches the model.
  Safe to poll on a short interval.
- Plan tier (e.g. "Max 5x") isn't in `/usage`'s output - it's in
  `~/.claude.json` → `oauthAccount.organizationRateLimitTier`.
