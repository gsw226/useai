import SwiftUI

// Menu bar clone of AI Limits Tracker. Endpoints/fields recovered from its Dart snapshot strings.
// ponytail: reuses Claude Code / Codex CLI logins instead of in-app OAuth; add OAuth if you want it standalone.

struct Win: Identifiable { let id = UUID(); let name: String; let used: Double; let reset: Date? }
struct Provider: Identifiable { let id: String; var wins: [Win] = []; var error: String? }
struct Fail: Error, LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func getJSON(_ url: String, _ headers: [String: String]) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: url)!)
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    let (d, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if CommandLine.arguments.contains("--dump") { print(url, code, String(decoding: d, as: UTF8.self)); fflush(stdout) }
    guard code == 200 else { throw Fail(code == 401 ? "토큰 만료 — CLI를 한 번 실행하세요" : code == 429 ? "요청 제한 중 — 이전 값 표시" : "HTTP \(code)") }
    return json(d)
}

// /usr/bin/security is already trusted by Claude Code's keychain item, so no access prompt.
func claudeToken() throws -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    let o = json(pipe.fileHandleForReading.readDataToEndOfFile())["claudeAiOauth"] as? [String: Any]
    guard let t = o?["accessToken"] as? String else { throw Fail("Claude Code 로그인 필요") }
    return t
}

let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
func iso(_ v: Any?) -> Date? { (v as? String).flatMap { isoFrac.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }

func fetchClaude() async throws -> [Win] {
    let j = try await getJSON("https://api.anthropic.com/api/oauth/usage",
                              ["Authorization": "Bearer \(try claudeToken())", "anthropic-beta": "oauth-2025-04-20"])
    let keys = [("five_hour", "5시간"), ("seven_day", "주간"), ("seven_day_opus", "주간 Opus"),
                ("seven_day_sonnet", "주간 Sonnet"), ("seven_day_fable", "주간 Fable")]
    return keys.compactMap { k, name in
        guard let w = j[k] as? [String: Any], let u = num(w["utilization"]) else { return nil }
        return Win(name: name, used: u, reset: iso(w["resets_at"]))
    }
}

func fetchCodex() async throws -> [Win] {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    guard let d = try? Data(contentsOf: url), let t = json(d)["tokens"] as? [String: Any],
          let at = t["access_token"] as? String else { throw Fail("codex login 필요") }
    var h = ["Authorization": "Bearer \(at)", "User-Agent": "codex_cli_rs"]
    if let a = t["account_id"] as? String { h["chatgpt-account-id"] = a }
    let rl = try await getJSON("https://chatgpt.com/backend-api/wham/usage", h)["rate_limit"] as? [String: Any] ?? [:]
    return ["primary_window", "secondary_window"].compactMap { k in
        guard let w = rl[k] as? [String: Any], let u = num(w["used_percent"]) else { return nil }
        let hrs = Int(num(w["limit_window_seconds"]) ?? 0) / 3600
        let reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            ?? num(w["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
        return Win(name: hrs >= 24 ? "주간" : "\(hrs)시간", used: u, reset: reset)
    }
}

@MainActor final class Store: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var updated: Date?
    func refresh() async {
        async let c = Result { try await fetchClaude() }
        async let x = Result { try await fetchCodex() }
        providers = [("Claude", await c), ("Codex", await x)].map { name, r in
            switch r {
            case .success(let w): Provider(id: name, wins: w)
            // keep last good numbers on failure (the Claude endpoint 429s easily)
            case .failure(let e): Provider(id: name, wins: providers.first { $0.id == name }?.wins ?? [],
                                           error: e.localizedDescription)
            }
        }
        updated = Date()
    }
    var minRemaining: Int? { providers.flatMap(\.wins).map { Int((100 - $0.used).rounded()) }.min() }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.providers) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.id).font(.headline)
                    if let e = p.error { Text(e).font(.caption).foregroundStyle(.secondary) }
                    ForEach(p.wins) { w in
                        HStack { Text(w.name); Spacer(); Text("남은 \(Int((100 - w.used).rounded()))%").monospacedDigit() }
                            .font(.callout)
                        ProgressView(value: min(w.used, 100), total: 100).tint(w.used >= 90 ? .red : w.used >= 70 ? .orange : .accentColor)
                        if let r = w.reset {
                            Text("리셋 \(r, style: .relative) 후").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let u = store.updated { Text(u, style: .time).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("새로고침") { Task { await store.refresh() } }
                Button("종료") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 280)
    }
}

@main struct UseAIApp: App {
    @StateObject var store = Store()
    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            Text(store.minRemaining.map { "AI \($0)%" } ?? "AI")
                .task { while true { await store.refresh(); try? await Task.sleep(for: .seconds(300)) } }
        }
        .menuBarExtraStyle(.window)
    }
}
