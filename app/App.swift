import SwiftUI

// Plan tier (e.g. "Max 5x"), read once from ~/.claude.json - not part of
// /usage's own output. Nil (shows nothing) if the file, field, or a
// recognizable format isn't there, e.g. API-key auth instead of a
// subscription.
let claudePlanName: String? = {
    let path = "\(NSHomeDirectory())/.claude.json"
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["oauthAccount"] as? [String: Any],
          var tier = oauth["organizationRateLimitTier"] as? String,
          !tier.isEmpty
    else { return nil }
    if tier.hasPrefix("default_") { tier.removeFirst("default_".count) }
    if tier.hasPrefix("claude_") { tier.removeFirst("claude_".count) }
    let words = tier.split(separator: "_").map { part -> String in
        if part.hasSuffix("x"), Int(part.dropLast()) != nil { return String(part) }
        return part.prefix(1).uppercased() + part.dropFirst()
    }
    return words.isEmpty ? nil : words.joined(separator: " ")
}()

// Claude Code mark for the menu bar. Loaded as a template NSImage with its
// .size set explicitly (in points) - and displayed with NO .resizable()/
// .frame() modifiers, so SwiftUI uses that intrinsic size directly, same as
// a plain Image(systemName:). Adding resizable()/frame() here previously
// made MenuBarExtra render nothing at all (it needs an intrinsic size before
// its own layout pass, which resizable() removes).
// All three menu bar icons share this exact box so swapping between them
// (idle/alert/100%) never resizes the status item - a size mismatch made
// the menu bar visibly flick every time the icon changed. The alert/100%
// mascots are natively ~1:1 and ~1.18:1 (vs. the plain mark's 1.6:1), so
// they get stretched a bit wider to fill the same box - which reads fine
// since it just gives the pixel-art body more width, same as widening it
// by hand would.
let menuBarIconBoxSize = NSSize(width: 16 * (24.0 / 15.0), height: 16)

func loadMenuBarImage(_ resource: String) -> NSImage {
    guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
          let image = NSImage(contentsOf: url)
    else { return NSImage() }
    image.isTemplate = true
    image.size = menuBarIconBoxSize
    return image
}

let menuBarMarkImage = loadMenuBarImage("menubar-mark")
// Pixel-grid mascot poses, shown instead of the plain mark once usage
// crosses the alert threshold / hits 100%.
let menuBarAlertImage = loadMenuBarImage("menubar-mark-alert")
let menuBar100Image = loadMenuBarImage("menubar-mark-100")

enum BlockKind: String {
    case session, weeklyAll, weeklyModel
}

struct UsageBlock: Identifiable {
    let id = UUID()
    let kind: BlockKind
    let label: String
    let percent: Int
    let resets: String
}

func regexMatch(_ pattern: String, in text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (1..<m.numberOfRanges).map {
        let r = m.range(at: $0)
        return r.location == NSNotFound ? "" : (text as NSString).substring(with: r)
    }
}

// claude's `/usage` output is free-form chat prose, not a stable API - the
// surrounding text (plan blurb, "What's contributing" breakdown, section
// order/presence) has changed before and will again. Anchoring to the whole
// multi-line shape is brittle. Instead scan line-by-line for the one
// substring that's actually load-bearing: "<label>: N% used", optionally
// followed by "resets ...". Everything else on the line (or around it) is
// ignored, so unrelated prose changes can't break parsing.
private let usageLinePattern = #"^(.+?):\s*(\d+)% used(?:.*?resets (.+))?$"#

func parseUsage(_ text: String) -> [UsageBlock] {
    var blocks: [UsageBlock] = []
    var weeklyAllResets = ""
    for line in text.components(separatedBy: "\n") {
        guard let m = regexMatch(usageLinePattern, in: line) else { continue }
        let label = m[0].trimmingCharacters(in: .whitespaces)
        let percent = Int(m[1]) ?? 0
        let lowered = label.lowercased()
        guard lowered.contains("session") || lowered.contains("week") else { continue }

        if lowered.contains("session") {
            blocks.append(UsageBlock(kind: .session, label: "Session (5 hour)", percent: percent, resets: m[2]))
        } else if lowered.contains("all models") {
            weeklyAllResets = m[2].isEmpty ? weeklyAllResets : m[2]
            blocks.append(UsageBlock(kind: .weeklyAll, label: "Weekly (7 day)", percent: percent, resets: m[2]))
        } else {
            // Per-model weekly lines sometimes omit "resets ..." (it'd just
            // repeat the "all models" line above) - fall back to that.
            let model = regexMatch(#"\(([^)]+)\)"#, in: label)?.first ?? label
            let resets = m[2].isEmpty ? weeklyAllResets : m[2]
            blocks.append(UsageBlock(kind: .weeklyModel, label: "Weekly \(model) (7 day)", percent: percent, resets: resets))
        }
    }
    return blocks
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var blocks: [UsageBlock] = []
    @Published var lastUpdated: Date?
    @Published var errorText: String?

    private var timer: Timer?
    private var lastAlertedPercent: Int?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task {
            do {
                var text = try await Self.runUsageCommand()
                var newBlocks = parseUsage(text)
                // Confirmed via real user output: claude's /usage in headless
                // (-p) mode can succeed (is_error: false) but skip the
                // "Current session/week" percentage lines entirely, jumping
                // straight to the "What's contributing" breakdown - a flake
                // in claude itself, not a connectivity/auth problem. One
                // retry clears it in practice, so don't surface an error for
                // what's actually a transient hiccup.
                if newBlocks.isEmpty {
                    text = try await Self.runUsageCommand()
                    newBlocks = parseUsage(text)
                }
                guard !newBlocks.isEmpty else {
                    // Still nothing after retry - could be a genuinely
                    // unrecognized output shape (API-key billing, wording
                    // drift) or a persistent claude-side issue. Log the raw
                    // text so this is actually diagnosable instead of just
                    // discarding it - "check your internet" is often wrong
                    // when claude ran fine but the text didn't parse.
                    NSLog("ClaudeUsage: /usage output didn't match expected format: %@", text)
                    let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                    self.errorText = snippet.isEmpty
                        ? "Got an unexpected (empty) response from claude - check your internet connection and that you're logged in."
                        : "Got an unexpected response from claude: \"\(snippet)\""
                    return
                }
                self.blocks = newBlocks
                self.lastUpdated = Date()
                self.errorText = nil
                checkThresholdAlert(newBlocks)
            } catch {
                self.errorText = "Make sure claude is installed, you're logged in, and you're online."
            }
        }
    }

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

    // Covers the common installs directly (fast, no shell spawn). Anything
    // else - nvm/volta/fnm-managed node, a custom npm prefix, pnpm/yarn
    // global bin, etc - won't be here, since those all depend on PATH setup
    // that lives in the user's shell rc files.
    nonisolated private static let knownClaudePaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    // Fallback for installs the fixed list above misses: ask the user's own
    // login shell to resolve "claude" the same way Terminal would, so
    // whatever PATH their rc files build (nvm, volta, custom prefixes, ...)
    // is honored instead of us guessing fixed locations.
    nonisolated private static func resolveClaudePathViaLoginShell() -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // -l -i: source the same profile/rc files an interactive Terminal
        // session would, so PATH matches what the user actually has.
        process.arguments = ["-l", "-i", "-c", "command -v claude"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func runUsageCommand() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let resolved = knownClaudePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                    ?? resolveClaudePathViaLoginShell()
                guard let claudePath = resolved else {
                    cont.resume(throwing: NSError(domain: "usage", code: 2, userInfo: [NSLocalizedDescriptionKey: "claude CLI not found"]))
                    return
                }
                var env = ProcessInfo.processInfo.environment
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
                env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                // --safe-mode skips plugin/MCP/hook loading (some plugin was triggering
                // macOS Photos/Downloads permission prompts on every launch) while still
                // reading the existing OAuth session - unlike --bare, which also disables
                // keychain reads and would break auth for subscription (non-API-key) users.
                process.arguments = ["--safe-mode", "-p", "/usage", "--output-format", "json"]
                process.environment = env
                // A GUI app launched from Finder/LaunchServices has no real cwd (usually
                // "/"), unlike Terminal which always starts at $HOME. claude likely falls
                // back to probing common folders (Desktop, Downloads...) when cwd doesn't
                // look like a normal project location - anchoring to $HOME mimics how
                // everyone already runs it from Terminal, where this never happens.
                process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    // Without this, a hung claude process (e.g. stuck on a dead
                    // network call) leaves the UI on "Loading…" forever with no
                    // way out - force it to fail instead of hanging indefinitely.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                        if process.isRunning { process.terminate() }
                    }
                    // Read before waiting on exit: if output fills the pipe buffer,
                    // waiting first deadlocks the child (blocked writing) against us
                    // (blocked waiting) since nothing is draining the pipe.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = obj["result"] as? String else {
                        cont.resume(throwing: NSError(domain: "usage", code: 1))
                        return
                    }
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var isChecking = false
    @Published var checkError: String?
    @Published var lastCheckedAt: Date?

    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.isNewer(latest, than: currentVersion)
    }

    init() {
        if UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
            check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true else { return }
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        isChecking = true
        Task {
            defer {
                isChecking = false
                lastCheckedAt = Date()
            }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/djalmaaraujo/claude-usage-menubar/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                latestVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                checkError = nil
            } catch {
                checkError = "Couldn't check for updates"
            }
        }
    }

    func updateAndRestart() {
        let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brewPath = brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            checkError = "Homebrew not found — run: brew upgrade --cask djalmaaraujo/tap/claude-usage-menubar"
            return
        }
        isChecking = true
        // `brew upgrade` replaces our OWN running executable on disk - macOS can
        // SIGKILL a process whose backing file changes mid-run (code-signing
        // re-validation on the next page-in), so we might never get to run any
        // Swift code after the upgrade starts. The relaunch can't depend on us
        // surviving to trigger it: hand the whole "upgrade then open" sequence to
        // a single detached shell process instead, then just ask to quit - if the
        // OS kills us first, the detached shell keeps running regardless.
        // `brew upgrade` only sees new cask versions after the tap's local clone
        // is refreshed - without `brew update` first, it just sees the old
        // version as "latest" and does nothing (reopens the same build).
        // stdin explicitly /dev/null (not just inherited) - if brew ever prompts
        // interactively (sudo password, analytics opt-in, etc) a blocked read
        // would hang this whole chain forever and "open" at the end would never
        // run, which looks exactly like "quit but never reopened". Logging to
        // a file too, since this runs fully detached from us with nowhere else
        // to surface a failure - a stuck/failed update is otherwise invisible.
        let logPath = "\(NSHomeDirectory())/Library/Logs/ClaudeUsage-update.log"
        let script = """
        { echo "=== update $(date) ==="; \
        "\(brewPath)" update; \
        "\(brewPath)" upgrade --cask djalmaaraujo/tap/claude-usage-menubar; echo "upgrade exit: $?"; \
        open /Applications/ClaudeUsage.app; echo "open exit: $?"; } </dev/null >> "\(logPath)" 2>&1
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UsageBarView: View {
    let block: UsageBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(block.label).font(.headline)
                Spacer()
                Text("Resets \(block.resets)").font(.caption).foregroundColor(.secondary)
            }
            ProgressView(value: Double(block.percent), total: 100)
                .tint(.green)
            Text("\(block.percent)% used").font(.caption).foregroundColor(.secondary)
        }
    }
}

let repoURL = URL(string: "https://github.com/djalmaaraujo/claude-usage-menubar")!

struct ContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @AppStorage("showProgressInMenuBar") private var showProgress = true
    @AppStorage("menuBarSourceKind") private var menuBarSourceKind = BlockKind.session.rawValue
    @AppStorage("alertsEnabled") private var alertsEnabled = false
    @AppStorage("alertThreshold") private var alertThreshold = 90
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let plan = claudePlanName {
                    Text("Claude Usage (\(plan))").font(.title2).bold()
                } else {
                    Text("Claude Usage").font(.title2).bold()
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
                HStack {
                    Image(systemName: "arrow.up.circle.fill").foregroundColor(.blue)
                    Text("Version \(latest) available").font(.caption)
                    Spacer()
                    Button(updateChecker.isChecking ? "Updating…" : "Update & Restart") {
                        updateChecker.updateAndRestart()
                    }
                    .disabled(updateChecker.isChecking)
                    .font(.caption)
                }
                .padding(8)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(8)
            }

            if let error = store.errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundColor(.orange)
                    Text("Can't reach Claude")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { store.refresh() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if store.blocks.isEmpty {
                Text("Loading…").foregroundColor(.secondary)
            } else {
                ForEach(store.blocks) { UsageBarView(block: $0) }
            }

            if alertsEnabled {
                HStack {
                    Text("Alert at").font(.caption).foregroundColor(.secondary)
                    Slider(value: Binding(
                        get: { Double(alertThreshold) },
                        set: { alertThreshold = Int($0.rounded()) }
                    ), in: 1...100, step: 1)
                    Text("\(alertThreshold)%")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Divider()

            HStack {
                // Only show update-check status if it's fresher than the last usage
                // refresh - otherwise "Up to date" would stick around forever after
                // one manual check, even once a newer refresh has happened.
                let updateStatusIsFresh = updateChecker.lastCheckedAt.map { checked in
                    guard let refreshed = store.lastUpdated else { return true }
                    return checked > refreshed
                } ?? false

                if updateChecker.isChecking {
                    Text("Checking for updates…").font(.caption).foregroundColor(.secondary)
                } else if updateStatusIsFresh, let updateError = updateChecker.checkError {
                    Text(updateError).font(.caption).foregroundColor(.red)
                } else if updateStatusIsFresh, updateChecker.latestVersion != nil, !updateChecker.updateAvailable {
                    Text("Up to date (v\(updateChecker.currentVersion))").font(.caption).foregroundColor(.secondary)
                } else if let updated = store.lastUpdated {
                    Text("Refreshed at \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Toggle("Show progress in menubar", isOn: $showProgress)
                    if !store.blocks.isEmpty {
                        Picker("Menu bar percentage", selection: $menuBarSourceKind) {
                            ForEach(store.blocks) { block in
                                Text(block.label).tag(block.kind.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    Section("Alerts (tracks the percentage above)") {
                        Toggle("Alert at threshold", isOn: $alertsEnabled)
                    }
                    Section("Updates") {
                        Toggle("Check for updates automatically", isOn: Binding(
                            get: { autoCheckUpdates },
                            set: { newValue in
                                autoCheckUpdates = newValue
                                if newValue { updateChecker.check() }
                            }
                        ))
                        Button("Check for Updates Now") { updateChecker.check() }
                            .disabled(updateChecker.isChecking)
                    }
                    Button("GitHub") { NSWorkspace.shared.open(repoURL) }
                    Divider()
                    Button("Quit Claude Usage v\(updateChecker.currentVersion)") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

@main
struct ClaudeUsageMenuApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("showProgressInMenuBar") private var showProgress = true
    @AppStorage("menuBarSourceKind") private var menuBarSourceKind = BlockKind.session.rawValue
    @AppStorage("alertsEnabled") private var alertsEnabled = false
    @AppStorage("alertThreshold") private var alertThreshold = 90

    var selectedBlock: UsageBlock? {
        guard store.errorText == nil, !store.blocks.isEmpty else { return nil }
        return store.blocks.first(where: { $0.kind.rawValue == menuBarSourceKind }) ?? store.blocks.first
    }

    var menuBarTitle: String? {
        selectedBlock.map { "\($0.percent)%" }
    }

    // 100% always wins regardless of the alert toggle (it's just true), the
    // threshold pose only shows if alerts are actually turned on.
    var menuBarIcon: NSImage {
        guard let percent = selectedBlock?.percent else { return menuBarMarkImage }
        if percent >= 100 { return menuBar100Image }
        if alertsEnabled && percent >= alertThreshold { return menuBarAlertImage }
        return menuBarMarkImage
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store, updateChecker: updateChecker)
        } label: {
            HStack(spacing: 0) {
                if store.errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    Image(nsImage: menuBarIcon)
                }
                if showProgress, let title = menuBarTitle {
                    Text(" \(title)")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
