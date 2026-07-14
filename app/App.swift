import SwiftUI

// Claude Code mark for the menu bar. Loaded as a template NSImage with its
// .size set explicitly (in points) - and displayed with NO .resizable()/
// .frame() modifiers, so SwiftUI uses that intrinsic size directly, same as
// a plain Image(systemName:). Adding resizable()/frame() here previously
// made MenuBarExtra render nothing at all (it needs an intrinsic size before
// its own layout pass, which resizable() removes).
let menuBarMarkImage: NSImage = {
    guard let url = Bundle.main.url(forResource: "menubar-mark", withExtension: "png"),
          let image = NSImage(contentsOf: url)
    else { return NSImage() }
    image.isTemplate = true
    image.size = NSSize(width: 12 * (24.0 / 15.0), height: 12)
    return image
}()

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
    @Published var didLoadTrigger = 0
    @Published var didAlertTrigger = 0

    private var timer: Timer?
    private var hasLoadedOnce = false
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
                if !hasLoadedOnce {
                    hasLoadedOnce = true
                    didLoadTrigger += 1
                }
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
            didAlertTrigger += 1
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
                process.arguments = ["-p", "/usage", "--output-format", "json"]
                process.environment = env
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
    @AppStorage("showProgressInMenuBar") private var showProgress = true
    @AppStorage("allowAnimations") private var allowAnimations = true
    @AppStorage("menuBarSourceKind") private var menuBarSourceKind = BlockKind.session.rawValue
    @AppStorage("alertsEnabled") private var alertsEnabled = false
    @AppStorage("alertThreshold") private var alertThreshold = 90

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
                if let updated = store.lastUpdated {
                    Text("Last updated: \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    if !store.blocks.isEmpty {
                        Section("Show in menu bar") {
                            Picker("", selection: $menuBarSourceKind) {
                                ForEach(store.blocks) { block in
                                    Text(block.label).tag(block.kind.rawValue)
                                }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                    Toggle("Show progress in menubar", isOn: $showProgress)
                    Toggle("Allow animations", isOn: $allowAnimations)
                    Section("Alerts") {
                        Toggle("Alert at threshold", isOn: $alertsEnabled)
                        Stepper("Threshold: \(alertThreshold)%", value: $alertThreshold, in: 1...100, step: 5)
                    }
                    Button("GitHub") { NSWorkspace.shared.open(repoURL) }
                    Divider()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
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
    @AppStorage("showProgressInMenuBar") private var showProgress = true
    @AppStorage("allowAnimations") private var allowAnimations = true
    @AppStorage("menuBarSourceKind") private var menuBarSourceKind = BlockKind.session.rawValue
    @State private var bounce = false

    var menuBarTitle: String? {
        guard store.errorText == nil, !store.blocks.isEmpty else { return nil }
        let block = store.blocks.first(where: { $0.kind.rawValue == menuBarSourceKind }) ?? store.blocks.first
        return block.map { "\($0.percent)%" }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 0) {
                if store.errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    Image(nsImage: menuBarMarkImage)
                }
                if showProgress, let title = menuBarTitle {
                    Text(" \(title)")
                }
            }
            .scaleEffect(bounce ? 1.35 : 1.0)
            .animation(.interpolatingSpring(stiffness: 300, damping: 10), value: bounce)
            .onChange(of: store.didLoadTrigger) { _ in triggerBounce() }
            .onChange(of: store.didAlertTrigger) { _ in triggerBounce() }
        }
        .menuBarExtraStyle(.window)
    }

    private func triggerBounce() {
        guard allowAnimations else { return }
        bounce = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { bounce = false }
    }
}
