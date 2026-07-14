# Release checklist

This app ships via a Homebrew cask in a **separate repo**:
`git@github.com:djalmaaraujo/homebrew-tap.git`, file `Casks/claude-usage-menubar.rb`.

A GitHub release in *this* repo is not enough on its own — the cask pins an
exact `version` + `sha256`, so it silently keeps serving the old build until
that file is updated too. Every release needs both halves:

1. Bump the version, build clean, zip it:
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
