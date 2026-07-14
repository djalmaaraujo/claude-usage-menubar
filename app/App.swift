import SwiftUI

// Claude Code mark for the menu bar. Loaded as a template NSImage with its
// .size set explicitly (in points) - and displayed with NO .resizable()/
// .frame() modifiers, so SwiftUI uses that intrinsic size directly, same as
// a plain Image(systemName:). Adding resizable()/frame() here previously
// made MenuBarExtra render nothing at all (it needs an intrinsic size before
// its own layout pass, which resizable() removes).
func loadMenuBarImage(_ resource: String, aspect: CGFloat) -> NSImage {
    guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
          let image = NSImage(contentsOf: url)
    else { return NSImage() }
    image.isTemplate = true
    image.size = NSSize(width: 16 * aspect, height: 16)
    return image
}

let menuBarMarkImage = loadMenuBarImage("menubar-mark", aspect: 24.0 / 15.0)
// Pixel-grid mascot poses, shown instead of the plain mark once usage
// crosses the alert threshold / hits 100%.
let menuBarAlertImage = loadMenuBarImage("menubar-mark-alert", aspect: 312.0 / 312.0)
let menuBar100Image = loadMenuBarImage("menubar-mark-100", aspect: 312.0 / 264.0)

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

func parseUsage(_ text: String) -> [UsageBlock] {
    var blocks: [UsageBlock] = []
    if let m = regexMatch(#"Current session:\s*(\d+)% used.*?resets ([^\n]+)"#, in: text) {
        blocks.append(UsageBlock(kind: .session, label: "Session (5 hour)", percent: Int(m[0]) ?? 0, resets: m[1]))
    }
    if let m = regexMatch(#"Current week \(all models\):\s*(\d+)% used.*?resets ([^\n]+)"#, in: text) {
        blocks.append(UsageBlock(kind: .weeklyAll, label: "Weekly (7 day)", percent: Int(m[0]) ?? 0, resets: m[1]))
    }
    if let m = regexMatch(#"Current week \((?!all models)([^)]+)\):\s*(\d+)% used.*?resets ([^\n]+)"#, in: text) {
        blocks.append(UsageBlock(kind: .weeklyModel, label: "Weekly \(m[0]) (7 day)", percent: Int(m[1]) ?? 0, resets: m[2]))
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
                let text = try await Self.runUsageCommand()
                let newBlocks = parseUsage(text)
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

    private static func runUsageCommand() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let candidates = [
                    "\(NSHomeDirectory())/.local/bin/claude",
                    "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude",
                ]
                guard let claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
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
        let script = "\"\(brewPath)\" update; \"\(brewPath)\" upgrade --cask djalmaaraujo/tap/claude-usage-menubar; open /Applications/ClaudeUsage.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
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
                Text("Claude Usage").font(.title2).bold()
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
                        Stepper("Threshold: \(alertThreshold)%", value: $alertThreshold, in: 1...100, step: 5)
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
