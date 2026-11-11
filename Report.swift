import Foundation

// Local token/cost report, like the original's UsageReport (REA ev_70646628: hourly buckets of
// input / cache-write 5m / 1h / cache-read / output per source+model, priced from pricing-default.json).
// USD per 1M tokens, copied from the original's bundled pricing table (2026-11-03).
let pricing: [(match: String, input: Double, w5m: Double, w1h: Double, read: Double, output: Double)] = [
    ("claude-fable-5-1", 10, 12.5, 20, 0.25, 50), ("claude-opus-5-5", 4, 5, 8, 0.2, 20),
    ("claude-sonnet-5-5", 2, 2.5, 4, 0.1, 10), ("claude-haiku-5-5", 0.1, 0.125, 0.2, 0.01, 0.5),
    ("claude-opus-5", 5, 6.25, 10, 0.5, 25), ("claude-sonnet-5", 2, 2.5, 4, 0.2, 10),
    ("claude-opus-4", 5, 6.25, 10, 0.5, 25), ("claude-sonnet-4", 3, 3.75, 6, 0.3, 15), ("claude-haiku-4-5", 1, 1.25, 2, 0.1, 5),
    ("gpt-6-astra", 10, 12.5, 12.5, 1, 50), ("gpt-6.1-sol", 2, 2.5, 2.5, 0.1, 10), ("gpt-6-luna", 0.1, 0.125, 0.125, 0.01, 0.5),
    ("gemini-3-flash-preview", 0.5, 0, 0, 0.05, 3),
]

struct ModelTotal: Identifiable { var id: String { source + model }
    let source: String; let model: String; var tokens = 0.0; var cost: Double? = 0
}

struct Tokens { var input = 0.0, w5m = 0.0, w1h = 0.0, read = 0.0, output = 0.0
    var total: Double { input + w5m + w1h + read + output }
    func cost(_ model: String) -> Double? {
        guard let p = pricing.first(where: { model.hasPrefix($0.match) }) else { return nil }
        return (input * p.input + w5m * p.w5m + w1h * p.w1h + read * p.read + output * p.output) / 1e6
    }
}

// ponytail: full rescan of this month's files on demand; add per-file offsets (the original's `cursors` table) if it gets slow.
func monthReport() -> [ModelTotal] {
    let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
    let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    var acc: [String: (String, String, Tokens)] = [:]
    func add(_ src: String, _ model: String, _ t: Tokens) {
        var cur = acc[src + model]?.2 ?? Tokens()
        cur.input += t.input; cur.w5m += t.w5m; cur.w1h += t.w1h; cur.read += t.read; cur.output += t.output
        acc[src + model] = (src, model, cur)
    }
    func files(_ dir: String) -> [URL] {
        let e = fm.enumerator(at: home.appendingPathComponent(dir), includingPropertiesForKeys: [.contentModificationDateKey])
        return (e?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "jsonl" && ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= start
        }
    }
    func lines(_ u: URL) -> [[String: Any]] {
        guard let s = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { json(Data($0.utf8)) }
    }

    // Claude Code: assistant messages carry message.usage; dedupe by message id + request id
    var seen = Set<String>()
    for f in files(".claude/projects") {
        for l in lines(f) {
            guard let m = l["message"] as? [String: Any], let u = m["usage"] as? [String: Any], let model = m["model"] as? String,
                  (date(l["timestamp"]) ?? .distantPast) >= start else { continue }
            let key = "\(m["id"] ?? ""):\(l["requestId"] ?? "")"
            guard seen.insert(key).inserted else { continue }
            let cc = u["cache_creation"] as? [String: Any]
            let w1h = num(cc?["ephemeral_1h_input_tokens"]) ?? 0
            let w5m = num(cc?["ephemeral_5m_input_tokens"]) ?? ((num(u["cache_creation_input_tokens"]) ?? 0) - w1h)
            add("Claude Code", model, Tokens(input: num(u["input_tokens"]) ?? 0, w5m: w5m, w1h: w1h,
                                             read: num(u["cache_read_input_tokens"]) ?? 0, output: num(u["output_tokens"]) ?? 0))
        }
    }
    // Codex: each session file ends with a cumulative total_token_usage (original keeps codex_totals per session)
    for f in files(".codex/sessions") {
        var model = "unknown", total: [String: Any]?
        for l in lines(f) {
            let p = l["payload"] as? [String: Any]
            if l["type"] as? String == "turn_context", let m = p?["model"] as? String { model = m }
            if p?["type"] as? String == "token_count", let t = (p?["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] { total = t }
        }
        guard let t = total else { continue }
        let cached = num(t["cached_input_tokens"]) ?? 0
        add("Codex", model, Tokens(input: (num(t["input_tokens"]) ?? 0) - cached, read: cached, output: num(t["output_tokens"]) ?? 0))
    }
    return acc.values.filter { $0.2.total > 0 }.map { ModelTotal(source: $0.0, model: $0.1, tokens: $0.2.total, cost: $0.2.cost($0.1)) }
        .sorted { ($0.cost ?? -1) > ($1.cost ?? -1) }
}
