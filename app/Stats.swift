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
