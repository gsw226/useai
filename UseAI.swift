import SwiftUI
import CryptoKit

// Menu bar clone of AI Limits Tracker. Endpoints/fields recovered from its Dart snapshot strings.
// ponytail: Codex still reuses the Codex CLI login (~/.codex/auth.json); add its localhost:1455 OAuth if needed.

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

let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
func iso(_ v: Any?) -> Date? { (v as? String).flatMap { isoFrac.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }

// --- Claude accounts: same OAuth client/flow the original app uses (Claude Code's public client, PKCE, paste-code) ---
let claudeClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
let claudeRedirect = "https://console.anthropic.com/oauth/code/callback"
let claudeUA = "claude-cli/2.1.280 (external, cli)" // exact string in the original snapshot (REA ev_ffa8cb30)

struct ClaudeAccount: Codable, Identifiable { var id: String; var access: String; var refresh: String; var expires: Date }

enum Vault { // all accounts as one JSON blob in the login keychain
    static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "UseAI", kSecAttrAccount as String: "claude-accounts"]
    static func load() -> [ClaudeAccount] {
        var q = base; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return [] }
        return (try? JSONDecoder().decode([ClaudeAccount].self, from: d)) ?? []
    }
    static func save(_ a: [ClaudeAccount]) {
        SecItemDelete(base as CFDictionary)
        var q = base; q[kSecValueData as String] = try! JSONEncoder().encode(a)
        SecItemAdd(q as CFDictionary, nil)
    }
}

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func randomB64(_ n: Int) -> String { b64url(Data((0..<n).map { _ in UInt8.random(in: 0...255) })) }

func authorizeURL(verifier: String, state: String) -> URL {
    var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
    c.queryItems = [("code", "true"), ("client_id", claudeClient), ("response_type", "code"),
                    ("redirect_uri", claudeRedirect), ("scope", "org:create_api_key user:profile user:inference"),
                    ("code_challenge", b64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
                    ("code_challenge_method", "S256"), ("state", state)].map(URLQueryItem.init)
    return c.url!
}

func tokenCall(_ body: [String: String]) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue(claudeUA, forHTTPHeaderField: "User-Agent")
    r.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (d, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw Fail("토큰 요청 실패 (HTTP \(code))") }
    return json(d)
}

func makeAccount(_ j: [String: Any], id: String?, oldRefresh: String = "") throws -> ClaudeAccount {
    guard let at = j["access_token"] as? String else { throw Fail("토큰 응답 이상") }
    let email = (j["account"] as? [String: Any])?["email_address"] as? String
    return ClaudeAccount(id: id ?? email ?? "Claude \(Int.random(in: 100...999))", access: at,
                         refresh: j["refresh_token"] as? String ?? oldRefresh,
                         expires: Date().addingTimeInterval(num(j["expires_in"]) ?? 3600))
}

func exchange(pasted: String, verifier: String, state: String) async throws -> ClaudeAccount {
    let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#").map(String.init)
    guard let code = parts.first, !code.isEmpty else { throw Fail("코드를 붙여넣으세요") }
    let j = try await tokenCall(["grant_type": "authorization_code", "code": code, "state": parts.count > 1 ? parts[1] : state,
                                 "client_id": claudeClient, "redirect_uri": claudeRedirect, "code_verifier": verifier])
    return try makeAccount(j, id: nil)
}

func refreshed(_ a: ClaudeAccount) async throws -> ClaudeAccount {
    let j = try await tokenCall(["grant_type": "refresh_token", "refresh_token": a.refresh, "client_id": claudeClient])
    return try makeAccount(j, id: a.id, oldRefresh: a.refresh)
}

func fetchClaude(token: String) async throws -> [Win] {
    let j = try await getJSON("https://api.anthropic.com/api/oauth/usage",
                              ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": claudeUA])
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
    @Published var accounts = Vault.load()
    @Published var login: (verifier: String, state: String)?
    @Published var pasted = ""
    @Published var loginError: String?

    func refresh() async {
        var out: [(String, Result<[Win], Error>)] = []
        for i in accounts.indices {
            let r = await Result {
                if accounts[i].expires < Date().addingTimeInterval(60) {
                    accounts[i] = try await refreshed(accounts[i]); Vault.save(accounts)
                }
                return try await fetchClaude(token: accounts[i].access)
            }
            out.append(("Claude · \(accounts[i].id)", r))
        }
        out.append(("Codex", await Result { try await fetchCodex() }))
        providers = out.map { name, r in
            switch r {
            case .success(let w): Provider(id: name, wins: w)
            // keep last good numbers on failure (the Claude endpoint 429s easily)
            case .failure(let e): Provider(id: name, wins: providers.first { $0.id == name }?.wins ?? [],
                                           error: e.localizedDescription)
            }
        }
        updated = Date()
    }

    func startLogin() {
        let l = (verifier: randomB64(32), state: randomB64(16))
        login = l; pasted = ""; loginError = nil
        NSWorkspace.shared.open(authorizeURL(verifier: l.verifier, state: l.state))
    }

    func finishLogin() async {
        guard let l = login else { return }
        do {
            let a = try await exchange(pasted: pasted, verifier: l.verifier, state: l.state)
            accounts.removeAll { $0.id == a.id }
            accounts.append(a); Vault.save(accounts)
            login = nil
            await refresh()
        } catch { loginError = error.localizedDescription }
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }; Vault.save(accounts)
        providers.removeAll { $0.id == "Claude · \(id)" }
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
                    HStack {
                        Text(p.id).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if p.id.hasPrefix("Claude · ") {
                            Button { store.remove(String(p.id.dropFirst(9))) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).help("계정 제거")
                        }
                    }
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
            if store.login != nil {
                Text("브라우저에서 승인 후 나온 코드를 붙여넣으세요").font(.caption)
                HStack {
                    TextField("code#state", text: $store.pasted).textFieldStyle(.roundedBorder)
                    Button("연결") { Task { await store.finishLogin() } }
                    Button("취소") { store.login = nil }
                }
                if let e = store.loginError { Text(e).font(.caption).foregroundStyle(.red) }
            } else {
                Button("Claude 계정 추가") { store.startLogin() }
            }
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
