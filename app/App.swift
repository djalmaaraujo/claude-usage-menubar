import SwiftUI

struct UsageBlock: Identifiable {
    let id = UUID()
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
        blocks.append(UsageBlock(label: "Session (5 hour)", percent: Int(m[0]) ?? 0, resets: m[1]))
    }
    if let m = regexMatch(#"Current week \(all models\):\s*(\d+)% used.*?resets ([^\n]+)"#, in: text) {
        blocks.append(UsageBlock(label: "Weekly (7 day)", percent: Int(m[0]) ?? 0, resets: m[1]))
    }
    if let m = regexMatch(#"Current week \((?!all models)([^)]+)\):\s*(\d+)% used.*?resets ([^\n]+)"#, in: text) {
        blocks.append(UsageBlock(label: "Weekly \(m[0]) (7 day)", percent: Int(m[1]) ?? 0, resets: m[2]))
    }
    return blocks
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var blocks: [UsageBlock] = []
    @Published var lastUpdated: Date?
    @Published var errorText: String?

    private var timer: Timer?

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
                self.blocks = parseUsage(text)
                self.lastUpdated = Date()
                self.errorText = nil
            } catch {
                self.errorText = "Couldn't reach claude CLI"
            }
        }
    }

    var menuBarTitle: String {
        guard let session = blocks.first else { return "…" }
        return "\(session.percent)%"
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
                Text(error).foregroundColor(.red)
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
                Button { NSWorkspace.shared.open(repoURL) } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.plain)
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

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                if showProgress {
                    Text(store.menuBarTitle)
                }
            }
            .contextMenu {
                Toggle("Show progress in menubar", isOn: $showProgress)
                Button("GitHub") { NSWorkspace.shared.open(repoURL) }
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
