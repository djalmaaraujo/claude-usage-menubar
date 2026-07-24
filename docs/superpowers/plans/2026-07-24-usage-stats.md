# Usage Stats (7-day chart + per-model breakdown) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 7-day daily-tokens bar chart and a per-model token breakdown (last 7 days) below the existing usage bars in the popover, sourced from local Claude Code session logs (`~/.claude/projects/**/*.jsonl`) — no `/stats` CLI command exists, so this is computed locally.

**Architecture:** New file `app/Stats.swift` holds a pure function (`computeUsageStats`) that scans and aggregates the jsonl logs, plus a `StatsStore` (`ObservableObject`, own 5-minute timer, background thread) that owns the published result. `ContentView` in `app/App.swift` gets a new section below the existing `Divider()` (`App.swift:475`) rendering the chart (Swift Charts) and model list. `ClaudeUsageMenuApp` creates and passes down the `StatsStore` the same way it already does for `UsageStore`/`UpdateChecker`.

**Tech Stack:** Swift, Foundation (`FileManager`, `JSONSerialization`, `ISO8601DateFormatter`), SwiftUI, Swift Charts (`import Charts`, available since macOS 13.0 — matches this project's existing target). No test framework in this project (single-file `swiftc` build, no Xcode project, confirmed in `docs/superpowers/plans/2026-07-23-notch-alert.md`) — verification is manual, via `build.sh` + running the built app + one Python cross-check script per the design spec's testing section.

## Global Constraints

- Tokens only, no cost in $ — see `docs/superpowers/specs/2026-07-24-usage-stats-design.md` ("Métrica"). No pricing table anywhere in this feature.
- New section goes below the existing popover content, same screen — no tabs, no separate view.
- Data is global: every `.jsonl` under `~/.claude/projects`, recursively, including `subagents/` subfolders. No per-project filter.
- Model names shown exactly as they appear in the log (e.g. `claude-sonnet-5`) — no display-name lookup table.
- No credits, no reset dates, no export/copy affordance — explicitly out of scope per the spec.
- `StatsStore` has its own 5-minute timer, independent of `UsageStore`'s existing 60-second timer (spec: jsonl parsing is heavier than an `/usage` call).
- Zero new external dependencies — this project has no SPM/Xcode project, just `swiftc App.swift Stats.swift NotchAlert.swift ... ` in `app/build.sh`. `Charts` is a system framework (ships with macOS 13+), so it's linked the same way `SwiftUI`/`AppKit` already are — no package manager involved.
- Bundle identifier for manual testing: `com.djalma.claudeusage` (from `app/Info.plist`).

---

### Task 1: Log scanning + aggregation core

**Files:**
- Create: `app/Stats.swift`
- Modify: `app/build.sh`

**Interfaces:**
- Produces:
  - `struct DayTokens: Identifiable { let id: String; let day: String; let tokens: Int }`
  - `struct ModelTokens: Identifiable { let id: String; let model: String; let tokens: Int }`
  - `struct UsageStats { let dailyTotals: [DayTokens]; let modelTotals: [ModelTokens]; let todayTokens: Int; let mostUsedModel: String? }`
  - `func computeUsageStats(logsRoot: URL, now: Date = Date()) -> UsageStats` — pure, synchronous, no threading/state. Used by Task 2's `StatsStore`.

- [ ] **Step 1: Create `app/Stats.swift` with the data model and aggregation function**

```swift
import Foundation

struct DayTokens: Identifiable {
    let id: String
    let day: String
    let tokens: Int
}

struct ModelTokens: Identifiable {
    let id: String
    let model: String
    let tokens: Int
}

struct UsageStats {
    let dailyTotals: [DayTokens]
    let modelTotals: [ModelTokens]
    let todayTokens: Int
    let mostUsedModel: String?
}

private let statsDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    return f
}()

private let statsISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// Scans every `.jsonl` session log under `logsRoot` (recursively - includes
// `subagents/` subfolders, which are separate transcripts with their own
// token usage, not duplicated in the parent session's log) and sums token
// usage per day/model for the last 7 days (today + 6 prior, local time
// zone). A file not modified within that window can't contain a line
// newer than its own mtime, so it's skipped without being opened - that's
// an exact filter, not an approximation.
func computeUsageStats(logsRoot: URL, now: Date = Date()) -> UsageStats {
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: now)
    guard let windowStart = calendar.date(byAdding: .day, value: -6, to: todayStart) else {
        return UsageStats(dailyTotals: [], modelTotals: [], todayTokens: 0, mostUsedModel: nil)
    }

    var perDay: [String: Int] = [:]
    var perModel: [String: Int] = [:]

    let fm = FileManager.default
    if let enumerator = fm.enumerator(
        at: logsRoot,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= windowStart,
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for line in contents.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      let usage = message["usage"] as? [String: Any],
                      let timestampString = obj["timestamp"] as? String,
                      let timestamp = statsISOFormatter.date(from: timestampString),
                      timestamp >= windowStart
                else { continue }

                let tokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)

                let day = statsDayFormatter.string(from: timestamp)
                perDay[day, default: 0] += tokens
                perModel[model, default: 0] += tokens
            }
        }
    }

    var dailyTotals: [DayTokens] = []
    for offset in stride(from: 6, through: 0, by: -1) {
        guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
        let key = statsDayFormatter.string(from: date)
        dailyTotals.append(DayTokens(id: key, day: key, tokens: perDay[key] ?? 0))
    }

    let modelTotals = perModel
        .map { ModelTokens(id: $0.key, model: $0.key, tokens: $0.value) }
        .sorted { $0.tokens > $1.tokens }

    let todayKey = statsDayFormatter.string(from: todayStart)
    let todayTokens = perDay[todayKey] ?? 0

    return UsageStats(
        dailyTotals: dailyTotals,
        modelTotals: modelTotals,
        todayTokens: todayTokens,
        mostUsedModel: modelTotals.first?.model
    )
}
```

- [ ] **Step 2: Wire `Stats.swift` into the build**

In `app/build.sh`, the `swiftc` invocation currently reads:

```bash
swiftc -parse-as-library -o "$APP/Contents/MacOS/ClaudeUsage" \
    App.swift \
    NotchAlert.swift \
    -framework SwiftUI -framework AppKit -framework ServiceManagement \
    -target arm64-apple-macos13.0
```

Change it to:

```bash
swiftc -parse-as-library -o "$APP/Contents/MacOS/ClaudeUsage" \
    App.swift \
    NotchAlert.swift \
    Stats.swift \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Charts \
    -target arm64-apple-macos13.0
```

- [ ] **Step 3: Build and verify it compiles**

Run: `cd /Users/cooper/dev/claude-usage-menubar/app && ./build.sh`
Expected: `Built: build/ClaudeUsage.app`, no compiler errors, app opens (existing behavior unchanged — `computeUsageStats` isn't called from anywhere yet).

- [ ] **Step 4: Manually cross-check the aggregation against a Python re-implementation**

Kill the test instance the build just opened first (don't leave duplicate menu bar icons around):

```bash
pkill -f "/Users/cooper/dev/claude-usage-menubar/app/build/ClaudeUsage.app"
```

Add a temporary debug entry point — append to the bottom of `app/Stats.swift`:

```swift
#if DEBUG_STATS_PRINT
func debugPrintStats() {
    let stats = computeUsageStats(logsRoot: URL(fileURLWithPath: "\(NSHomeDirectory())/.claude/projects"))
    for d in stats.dailyTotals { print("\(d.day): \(d.tokens)") }
    for m in stats.modelTotals { print("\(m.model): \(m.tokens)") }
    print("today: \(stats.todayTokens), mostUsed: \(stats.mostUsedModel ?? "nil")")
}
#endif
```

Temporarily add `debugPrintStats()` as the first line of `ClaudeUsageMenuApp.init()` in `app/App.swift` (find the existing `init()` added for the login-item sync), rebuild with the flag, and capture output:

```bash
cd /Users/cooper/dev/claude-usage-menubar/app
swiftc -parse-as-library -DDEBUG_STATS_PRINT -o /tmp/stats_debug_test \
    App.swift NotchAlert.swift Stats.swift \
    -framework SwiftUI -framework AppKit -framework ServiceManagement -framework Charts \
    -target arm64-apple-macos13.0
/tmp/stats_debug_test 2>&1 | head -20 &
sleep 2 && kill %1 2>/dev/null
```

Compare against an independent Python pass over the same files:

```bash
python3 - <<'EOF'
import json, glob, datetime, collections

root = f"{__import__('os').path.expanduser('~')}/.claude/projects"
now = datetime.datetime.now().astimezone()
window_start = (now - datetime.timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)

per_day = collections.defaultdict(int)
per_model = collections.defaultdict(int)

for path in glob.glob(f"{root}/**/*.jsonl", recursive=True):
    mtime = datetime.datetime.fromtimestamp(__import__('os').path.getmtime(path)).astimezone()
    if mtime < window_start:
        continue
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") != "assistant":
                continue
            msg = d.get("message", {})
            usage = msg.get("usage")
            model = msg.get("model")
            ts = d.get("timestamp")
            if not (usage and model and ts):
                continue
            timestamp = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
            if timestamp < window_start:
                continue
            tokens = sum(usage.get(k, 0) or 0 for k in
                ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"])
            day = timestamp.strftime("%Y-%m-%d")
            per_day[day] += tokens
            per_model[model] += tokens

for day in sorted(per_day):
    print(day, per_day[day])
for model, tokens in sorted(per_model.items(), key=lambda x: -x[1]):
    print(model, tokens)
EOF
```

Expected: per-day and per-model totals from both outputs match (small ordering differences in which days print are fine, values must agree). If they don't match, fix `computeUsageStats` before moving on — do not proceed with a silently wrong aggregation.

Remove the temporary `#if DEBUG_STATS_PRINT` block from `app/Stats.swift` and the `debugPrintStats()` call from `app/App.swift` afterward, and delete `/tmp/stats_debug_test`.

- [ ] **Step 5: Commit**

```bash
cd /Users/cooper/dev/claude-usage-menubar
git add app/Stats.swift app/build.sh
git commit -m "Add local jsonl log aggregation for 7-day token usage stats"
```

---

### Task 2: `StatsStore` (background refresh, own timer)

**Files:**
- Modify: `app/Stats.swift`

**Interfaces:**
- Consumes: `computeUsageStats(logsRoot:now:) -> UsageStats` (Task 1).
- Produces: `@MainActor final class StatsStore: ObservableObject` with `@Published var stats: UsageStats` — constructed once in `ClaudeUsageMenuApp` (Task 3), read by `ContentView` (Task 3).

- [ ] **Step 1: Append `StatsStore` to `app/Stats.swift`**

```swift
@MainActor
final class StatsStore: ObservableObject {
    @Published var stats = UsageStats(dailyTotals: [], modelTotals: [], todayTokens: 0, mostUsedModel: nil)

    private var timer: Timer?
    private let logsRoot = URL(fileURLWithPath: "\(NSHomeDirectory())/.claude/projects")

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let root = logsRoot
        Task {
            let result = await Task.detached(priority: .utility) {
                computeUsageStats(logsRoot: root)
            }.value
            self.stats = result
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd /Users/cooper/dev/claude-usage-menubar/app && ./build.sh`
Expected: `Built: build/ClaudeUsage.app`, no compiler errors. `StatsStore` isn't instantiated anywhere yet, so no behavior change.

Kill the test instance the build opened:

```bash
pkill -f "/Users/cooper/dev/claude-usage-menubar/app/build/ClaudeUsage.app"
```

- [ ] **Step 3: Commit**

```bash
cd /Users/cooper/dev/claude-usage-menubar
git add app/Stats.swift
git commit -m "Add StatsStore with its own 5-minute background refresh timer"
```

---

### Task 3: UI section (chart + model list) and wiring

**Files:**
- Modify: `app/App.swift`

**Interfaces:**
- Consumes: `StatsStore` (Task 2), `DayTokens`/`ModelTokens`/`UsageStats` (Task 1).
- Produces: nothing new consumed elsewhere — this is the leaf/UI task.

- [ ] **Step 1: Add `import Charts` and instantiate `StatsStore`**

At the top of `app/App.swift`, change:

```swift
import SwiftUI
import ServiceManagement
```

to:

```swift
import SwiftUI
import ServiceManagement
import Charts
```

In `ClaudeUsageMenuApp` (`App.swift`), it currently has:

```swift
@StateObject private var store = UsageStore()
@StateObject private var updateChecker = UpdateChecker()
```

Add a third `@StateObject`:

```swift
@StateObject private var store = UsageStore()
@StateObject private var updateChecker = UpdateChecker()
@StateObject private var statsStore = StatsStore()
```

And where `ContentView` is constructed:

```swift
ContentView(store: store, updateChecker: updateChecker)
```

change to:

```swift
ContentView(store: store, updateChecker: updateChecker, statsStore: statsStore)
```

- [ ] **Step 2: Accept `StatsStore` in `ContentView` and add the section**

In `app/App.swift`, `ContentView` currently declares:

```swift
struct ContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
```

Change to:

```swift
struct ContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var statsStore: StatsStore
```

Then, in the `body`, find the existing `Divider()` right before the footer `HStack` (the one containing the refresh-status text and the gear `Menu`, `App.swift:475`). Insert the new section between that `Divider()` and the footer `HStack`:

```swift
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Today: \(statsStore.stats.todayTokens.formatted()) tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if statsStore.stats.dailyTotals.allSatisfy({ $0.tokens == 0 }) {
                    Text("No local usage data in the last 7 days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Chart(statsStore.stats.dailyTotals) { day in
                        BarMark(
                            x: .value("Day", day.day),
                            y: .value("Tokens", day.tokens)
                        )
                        .foregroundStyle(.green)
                    }
                    .frame(height: 80)
                }

                if !statsStore.stats.modelTotals.isEmpty {
                    let totalModelTokens = statsStore.stats.modelTotals.reduce(0) { $0 + $1.tokens }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Usage by model (7 days)").font(.caption).bold()
                        ForEach(statsStore.stats.modelTotals) { model in
                            HStack {
                                Text(model.model).font(.caption)
                                Spacer()
                                Text("\(model.tokens.formatted()) (\(totalModelTokens > 0 ? Int(Double(model.tokens) / Double(totalModelTokens) * 100) : 0)%)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if let topModel = statsStore.stats.mostUsedModel {
                        Text("Most used model: \(topModel)")
                            .font(.caption)
                            .bold()
                    }
                }
            }

            Divider()
```

Note: `Chart(statsStore.stats.dailyTotals)` relies on `DayTokens` being `Identifiable` (Task 1) — Swift Charts' `Chart(_:content:)` init requires `RandomAccessCollection` of `Identifiable` data, which `[DayTokens]` satisfies. The `day.day` value fed to the x-axis is a `"yyyy-MM-dd"` string, not a `Date`, so `BarMark(x: .value("Day", day.day), ...)` renders it as a nominal (string) axis with the raw date strings as labels — that's fine for exactly 7 fixed categories, already in oldest→newest order since `dailyTotals` is built that way in Task 1.

- [ ] **Step 3: Build**

Run: `cd /Users/cooper/dev/claude-usage-menubar/app && ./build.sh`
Expected: `Built: build/ClaudeUsage.app`, no compiler errors.

- [ ] **Step 4: Manually verify in the running app**

```bash
pgrep -fl ClaudeUsage.app
```

If a previous test instance or the installed app is running, note its PID(s) but don't kill the installed `/Applications/ClaudeUsage.app` one without checking with the user first — this step only needs the freshly built test instance, which `build.sh` already opened.

Click the `ClaudeUsage` icon in the menu bar to open the popover. Expected, below the existing session/weekly bars and the (optional) alert slider:
- A `Divider()`.
- "Today: N tokens" line.
- Either the 7-bar chart (if there's any local usage in the last 7 days — there will be, since this very session is being logged right now) or the "No local usage data..." fallback text.
- "Usage by model (7 days)" list with at least one row (this session's model, e.g. `claude-sonnet-5`), each showing tokens + percentage.
- "Most used model: <model>" line.
- The existing footer (refresh status + gear menu) still renders correctly below the new second `Divider()`.

Take a screenshot to confirm layout doesn't clip or overflow the popover's fixed `320`-width frame (`App.swift:533`, `.frame(width: 320)`):

```bash
screencapture -x /tmp/stats-section-check.png
```

Then quit the test instance:

```bash
pkill -f "/Users/cooper/dev/claude-usage-menubar/app/build/ClaudeUsage.app"
```

- [ ] **Step 5: Commit**

```bash
cd /Users/cooper/dev/claude-usage-menubar
git add app/App.swift
git commit -m "Show 7-day usage chart and per-model breakdown in the popover"
```

---

## Self-Review Notes

- **Spec coverage:** métrica tokens-only (Task 1, no cost anywhere) · layout below existing content (Task 3, inserted after the pre-footer `Divider()`) · global scope across all projects/subagents (Task 1, `logsRoot` = `~/.claude/projects`, no project filter) · own 5-minute timer (Task 2) · "Today" + chart + model box + "Most used model" (Task 3) · empty-state handling (Task 3, `allSatisfy({ $0.tokens == 0 })` fallback text) · mtime pre-filter + whole-file read per the amended spec (Task 1). All covered.
- **Placeholder scan:** none — every step has literal code, exact commands, and stated expected output.
- **Type consistency:** `DayTokens`/`ModelTokens`/`UsageStats` defined in Task 1 are used unchanged in Task 2 (`StatsStore.stats: UsageStats`) and Task 3 (`statsStore.stats.dailyTotals`, `.modelTotals`, `.todayTokens`, `.mostUsedModel`) — same field names throughout.
