# Notch Alert Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When usage crosses the existing configurable alert threshold, show a
custom notch-shaped `NSPanel` (styled like Dynamic Island) on notched
MacBooks, in addition to the existing sound/icon alert.

**Architecture:** New file `app/NotchAlert.swift` holds a `NotchAlertController`
(owns a borderless, non-activating `NSPanel` pinned over the screen's notch
cutout) and a `NotchAlertView` (SwiftUI pill: icon + "N% · Label"). The
existing `checkThresholdAlert` in `App.swift` calls
`NotchAlertController.shared.show(percent:label:)` alongside its current
`NSSound` call. No new dependencies — `build.sh` just compiles the extra file.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSPanel`, `NSScreen`, `NSAnimationContext`), QuartzCore (`CAMediaTimingFunction`). No test framework in this project (single-file `swiftc` build, no Xcode project) — verification is manual, via `build.sh` + running the built app.

## Global Constraints

- No ActivityKit, no Dynamic Island (real), no iOS companion app — spec ruled this out, framework doesn't exist on macOS. See `docs/superpowers/specs/2026-07-23-notch-alert-design.md`.
- Zero new dependencies — project has no SPM/Xcode project, just `swiftc App.swift ...`. Any new file must be added to the `swiftc` invocation in `build.sh`, not pulled in via a package manager.
- Panel only appears on a screen with a physical notch (`NSScreen.auxiliaryTopLeftArea`/`auxiliaryTopRightArea` both non-nil). No screen with a notch → silent no-op, existing sound+icon behavior is unaffected.
- Trigger condition: reuses the existing `alertsEnabled`/`alertThreshold` guard in `checkThresholdAlert` (`App.swift:167-180`) — same crossing, no new threshold logic.
- Content: percent + block label only (e.g. "92% · Session (5 hour)"). No reset time, no multi-block view.
- Auto-dismiss after ~5s, no close button, no persistent pill.
- Clicking the panel while visible opens the app's main popover (via the `NSStatusBarWindow`/`NSStatusItem` KVC lookup — this is a private-API-shaped hack, accepted per user decision) and dismisses the panel immediately.
- Bundle identifier for manual testing: `com.djalma.claudeusage` (from `app/Info.plist`).

---

### Task 1: Notch detection + build wiring

**Files:**
- Create: `app/NotchAlert.swift`
- Modify: `app/build.sh`

**Interfaces:**
- Produces: `func notchScreen() -> NSScreen?` — top-level function, returns the first screen with a physical notch, or `nil` if none.

- [ ] **Step 1: Create `app/NotchAlert.swift` with the detection helper**

```swift
import SwiftUI
import AppKit

// A notch-having screen exposes non-nil auxiliary areas flanking the notch
// (the strips of menu bar to its left/right) - available since macOS 12.
// Screens without a notch (external displays, older MacBooks, iMac/mini)
// report nil for both, which is how we gate the whole feature off on them.
func notchScreen() -> NSScreen? {
    NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
}
```

- [ ] **Step 2: Wire the new file into the build**

In `app/build.sh`, the `swiftc` invocation currently reads:

```bash
swiftc -parse-as-library -o "$APP/Contents/MacOS/ClaudeUsage" \
    App.swift \
    -framework SwiftUI -framework AppKit \
    -target arm64-apple-macos13.0
```

Change it to:

```bash
swiftc -parse-as-library -o "$APP/Contents/MacOS/ClaudeUsage" \
    App.swift \
    NotchAlert.swift \
    -framework SwiftUI -framework AppKit \
    -target arm64-apple-macos13.0
```

- [ ] **Step 3: Build and verify it compiles**

Run: `cd /Users/cooper/dev/claude-usage-menubar/app && ./build.sh`
Expected: `Built: build/ClaudeUsage.app` printed, no compiler errors, app opens (existing behavior unchanged — `notchScreen()` isn't called from anywhere yet).

- [ ] **Step 4: Manually verify detection on a notched Mac (skip if testing on a non-notched Mac — note it in the commit message instead)**

Temporarily add `NSLog("notchScreen: \(notchScreen() != nil)")` at the top of `ClaudeUsageMenuApp.body` in `App.swift`, rebuild, run, then check Console.app (filter process `ClaudeUsage`) for the log line. Expected `true` on a notched MacBook (14"/16" Pro 2021+ built-in display), `false` on external-only/non-notched setups. Remove the temporary `NSLog` line afterward.

- [ ] **Step 5: Commit**

```bash
cd /Users/cooper/dev/claude-usage-menubar
git add app/NotchAlert.swift app/build.sh
git commit -m "Add notch detection helper and wire NotchAlert.swift into the build"
```

---

### Task 2: Notch panel — view, controller, show/dismiss, integration

**Files:**
- Modify: `app/NotchAlert.swift`
- Modify: `app/App.swift:167-180` (`checkThresholdAlert`)

**Interfaces:**
- Consumes: `notchScreen() -> NSScreen?` (Task 1).
- Produces: `NotchAlertController.shared.show(percent: Int, label: String)` and `NotchAlertController.shared.dismiss()` — used by Task 3 (click handling) and by `checkThresholdAlert`.

- [ ] **Step 1: Add the SwiftUI pill view**

Append to `app/NotchAlert.swift`:

```swift
struct NotchAlertView: View {
    let percent: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow)
            Text("\(percent)% · \(label)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black)
        .clipShape(Capsule())
    }
}
```

- [ ] **Step 2: Add the panel controller (show + auto-dismiss, no click handling yet)**

Append to `app/NotchAlert.swift` (add `import QuartzCore` at the top of the file alongside the existing imports):

```swift
@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    private static let collapsedWidth: CGFloat = 40
    private static let expandedWidth: CGFloat = 200
    private static let panelHeight: CGFloat = 32
    private static let visibleDuration: TimeInterval = 5

    private(set) var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(percent: Int, label: String) {
        guard let screen = notchScreen(),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return }

        dismissWorkItem?.cancel()
        panel?.orderOut(nil)

        let centerX = (left.maxX + right.minX) / 2
        let originY = screen.frame.maxY - Self.panelHeight - 2
        let collapsedFrame = NSRect(x: centerX - Self.collapsedWidth / 2, y: originY, width: Self.collapsedWidth, height: Self.panelHeight)
        let expandedFrame = NSRect(x: centerX - Self.expandedWidth / 2, y: originY, width: Self.expandedWidth, height: Self.panelHeight)

        let hostingView = NSHostingView(rootView: NotchAlertView(percent: percent, label: label))
        hostingView.frame = NSRect(origin: .zero, size: expandedFrame.size)

        let newPanel = NSPanel(
            contentRect: collapsedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .statusBar
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.contentView = hostingView
        newPanel.alphaValue = 0

        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(expandedFrame, display: true)
        }

        scheduleDismiss()
    }

    private func scheduleDismiss() {
        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        guard let panel else { return }
        let collapsedFrame = NSRect(
            x: panel.frame.midX - Self.collapsedWidth / 2,
            y: panel.frame.origin.y,
            width: Self.collapsedWidth,
            height: Self.panelHeight
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(collapsedFrame, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        })
    }
}
```

- [ ] **Step 3: Integrate into the existing threshold check**

In `app/App.swift`, `checkThresholdAlert` currently reads (`App.swift:167-180`):

```swift
    private func checkThresholdAlert(_ blocks: [UsageBlock]) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "alertsEnabled") else { lastAlertedPercent = nil; return }
        let threshold = d.object(forKey: "alertThreshold") as? Int ?? 90
        let kindRaw = d.string(forKey: "menuBarSourceKind") ?? BlockKind.session.rawValue
        guard let block = blocks.first(where: { $0.kind.rawValue == kindRaw }) ?? blocks.first else { return }
        if block.percent >= threshold {
            guard lastAlertedPercent == nil else { return }
            lastAlertedPercent = block.percent
            NSSound(named: "Glass")?.play()
        } else {
            lastAlertedPercent = nil
        }
    }
```

Change the `NSSound` line to also show the notch panel:

```swift
        if block.percent >= threshold {
            guard lastAlertedPercent == nil else { return }
            lastAlertedPercent = block.percent
            NSSound(named: "Glass")?.play()
            NotchAlertController.shared.show(percent: block.percent, label: block.label)
        } else {
            lastAlertedPercent = nil
        }
```

- [ ] **Step 4: Build**

Run: `cd /Users/cooper/dev/claude-usage-menubar/app && ./build.sh`
Expected: `Built: build/ClaudeUsage.app`, no compiler errors.

- [ ] **Step 5: Manually verify the panel shows and auto-dismisses (notched Mac only)**

Force a trigger using the app's real usage data (no mocking needed — any nonzero percent clears a threshold of 1):

```bash
defaults write com.djalma.claudeusage alertsEnabled -bool true
defaults write com.djalma.claudeusage alertThreshold -int 1
open /Users/cooper/dev/claude-usage-menubar/app/build/ClaudeUsage.app
```

Expected: within ~60s (the refresh timer interval) the notch panel expands showing "N% · <label>", stays ~5s, then shrinks/fades away on its own. Glass sound plays at the same moment (existing behavior, unchanged).

Then revert the test defaults:

```bash
defaults write com.djalma.claudeusage alertsEnabled -bool false
defaults delete com.djalma.claudeusage alertThreshold
```

- [ ] **Step 6: Manually verify the no-notch fallback (if you have access to a non-notched Mac or external-only setup)**

Same steps as above on a Mac where `notchScreen()` returns `nil`. Expected: no panel appears, Glass sound still plays, no crash, nothing printed to Console beyond the usual app logs.

- [ ] **Step 7: Commit**

```bash
cd /Users/cooper/dev/claude-usage-menubar
git add app/NotchAlert.swift app/App.swift
git commit -m "Show notch alert panel when usage crosses the configured threshold"
```

---

### Task 3: Click-to-dismiss and open the main popover

**Files:**
- Modify: `app/NotchAlert.swift`

**Interfaces:**
- Consumes: `NotchAlertController.shared.dismiss()` (Task 2).
- Produces: `NotchAlertController.shared.handleClick()` — called by the SwiftUI view's tap gesture.

- [ ] **Step 1: Add the click handler and the KVC lookup for the menu bar's status item**

`MenuBarExtra(style: .window)` doesn't expose its `NSStatusItem` publicly. The
established workaround (used by libraries like MenuBarExtraAccess): find the
internal `NSStatusBarWindow` in `NSApp.windows` by class name, read its
`statusItem` property via KVC, then simulate a click on the status item's
button — that's exactly what a real user clicking the menu bar icon does, so
it opens the same popover.

Append to `app/NotchAlert.swift`, inside `NotchAlertController`:

```swift
    func handleClick() {
        dismiss()
        openMainPopover()
    }

    private func openMainPopover() {
        guard let statusBarWindow = NSApp.windows.first(where: {
            String(describing: type(of: $0)) == "NSStatusBarWindow"
        }), let statusItem = statusBarWindow.value(forKey: "statusItem") as? NSStatusItem
        else { return }
        statusItem.button?.performClick(nil)
    }
```

- [ ] **Step 2: Wire the tap gesture in the view**

In `app/NotchAlert.swift`, change `NotchAlertView`'s body to add `.onTapGesture`:

```swift
struct NotchAlertView: View {
    let percent: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow)
            Text("\(percent)% · \(label)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            NotchAlertController.shared.handleClick()
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `cd /Users/cooper/dev/claude-usage-menubar/app && ./build.sh`
Expected: `Built: build/ClaudeUsage.app`, no compiler errors.

- [ ] **Step 4: Manually verify click behavior (notched Mac only)**

```bash
defaults write com.djalma.claudeusage alertsEnabled -bool true
defaults write com.djalma.claudeusage alertThreshold -int 1
open /Users/cooper/dev/claude-usage-menubar/app/build/ClaudeUsage.app
```

Wait for the panel to appear, then click it before the ~5s auto-dismiss.
Expected: panel disappears immediately, and the app's main popover (the one
that normally opens from clicking the menu bar icon) opens.

Revert the test defaults:

```bash
defaults write com.djalma.claudeusage alertsEnabled -bool false
defaults delete com.djalma.claudeusage alertThreshold
```

- [ ] **Step 5: Manually verify repeated crossings don't spam the panel**

With `alertsEnabled` still on a low threshold from the previous step (or set it again), let the app run through a few refresh cycles (60s apart) without the percent dropping below threshold. Expected: panel shows once on the initial crossing, does not reappear on subsequent refreshes while `block.percent` stays `>= threshold` (this is `lastAlertedPercent` guarding it, unchanged from existing behavior — `App.swift:174`). Revert defaults afterward as in Step 4.

- [ ] **Step 6: Commit**

```bash
cd /Users/cooper/dev/claude-usage-menubar
git add app/NotchAlert.swift
git commit -m "Open the main popover when the notch alert panel is clicked"
```
