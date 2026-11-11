import Foundation
import CryptoKit
import Network

// Endpoints, client IDs and field names come from REA analysis of AI Limits Tracker 1.1.2
// (string evidence ev_ffa8cb30, ev_f4b6ba18, ev_314fec1e). Antigravity's Google client/endpoints
// are not in the snapshot; those use the public Antigravity values (unverified).

struct Win: Identifiable, Codable { var id: String { name }; let name: String; let used: Double; let reset: Date? }
struct Fail: Error, LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }
struct AuthExpired: Error, LocalizedError { var errorDescription: String? { "로그인 만료 — 다시 연결하세요" } }

enum Kind: String, Codable, CaseIterable { case claude, codex, grok, antigravity
    var title: String { ["claude": "Claude", "codex": "Codex", "grok": "Grok", "antigravity": "Antigravity"][rawValue]! }
}

struct Account: Codable, Identifiable {
    var kind: Kind; var label: String; var access: String; var refresh: String; var expires: Date
    var extra: [String: String] = [:]
    var id: String { "\(kind.rawValue):\(label)" }
    init(kind: Kind, label: String, access: String, refresh: String, expires: Date, extra: [String: String] = [:]) {
        self.kind = kind; self.label = label; self.access = access; self.refresh = refresh; self.expires = expires; self.extra = extra
    }
    // reads the v1 format too ({id, access, refresh, expires}, Claude only)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .claude
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? c.decode(String.self, forKey: .id)
        access = try c.decode(String.self, forKey: .access); refresh = try c.decode(String.self, forKey: .refresh)
        expires = try c.decode(Date.self, forKey: .expires)
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(kind, forKey: .kind); try c.encode(label, forKey: .label); try c.encode(access, forKey: .access)
        try c.encode(refresh, forKey: .refresh); try c.encode(expires, forKey: .expires); try c.encode(extra, forKey: .extra)
    }
    enum K: String, CodingKey { case kind, label, id, access, refresh, expires, extra }
}

enum Vault { // all accounts as one JSON blob in the login keychain
    static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "UseAI", kSecAttrAccount as String: "claude-accounts"]
    static func load() -> [Account] {
        var q = base; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: d)) ?? []
    }
    static func save(_ a: [Account]) {
        SecItemDelete(base as CFDictionary)
        var q = base; q[kSecValueData as String] = try! JSONEncoder().encode(a)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - HTTP helpers

func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
let dumping = CommandLine.arguments.contains("--dump")

func request(_ url: String, method: String = "GET", headers: [String: String] = [:],
             json body: [String: Any]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    if let body {
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
    } else if let form {
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0, value: $1) }
        r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    let (d, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if dumping { print(method, url, code, String(decoding: d, as: UTF8.self)); fflush(stdout) }
    if code == 401 { throw AuthExpired() }
    guard (200..<300).contains(code) else {
        throw Fail(code == 429 ? "요청 제한 중 — 이전 값 표시" : "HTTP \(code)")
    }
    return json(d)
}

let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
func date(_ v: Any?) -> Date? {
    if let s = v as? String { return isoFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
    return num(v).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
}

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func randomB64(_ n: Int) -> String { b64url(Data((0..<n).map { _ in UInt8.random(in: 0...255) })) }
func challenge(_ verifier: String) -> String { b64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

func jwt(_ t: String?) -> [String: Any] {
    guard let p = t?.split(separator: ".").dropFirst().first else { return [:] }
    var s = p.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s).map(json) ?? [:]
}

/// Depth-first lookup of the first value under `key` anywhere in a JSON tree.
func find(_ key: String, in o: Any?) -> Any? {
    if let d = o as? [String: Any] { if let v = d[key] { return v }; return d.values.lazy.compactMap { find(key, in: $0) }.first }
    if let a = o as? [Any] { return a.lazy.compactMap { find(key, in: $0) }.first }
    return nil
}

// MARK: - Loopback OAuth callback (Codex 1455, Grok/Antigravity 22255 — ports from the original)

func waitForCallback(port: UInt16, onReady: @escaping @Sendable () -> Void) async throws -> [String: String] {
    try await withCheckedThrowingContinuation { cont in
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            return cont.resume(throwing: Fail("포트 \(port) 사용 중 — 다른 로그인 창을 닫으세요"))
        }
        var done = false
        func finish(_ r: Result<[String: String], Error>) { if !done { done = true; l.cancel(); cont.resume(with: r) } }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let q = Dictionary((URLComponents(string: "http://localhost" + path)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                let page = "<meta charset=utf-8><h3 style='font-family:-apple-system'>연결 완료 — 앱으로 돌아가세요</h3>"
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(page)".utf8),
                       completion: .contentProcessed { _ in c.cancel() })
                if q["code"] != nil { finish(.success(q)) } else if let e = q["error"] { finish(.failure(Fail(e))) }
            }
        }
        l.stateUpdateHandler = {
            if case .failed(let e) = $0 { finish(.failure(e)) }
            if case .ready = $0 { onReady() }
        }
        l.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(.failure(Fail("로그인 시간 초과"))) }
    }
}

// MARK: - Provider definitions

let claudeClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
// The original app (1.1.2) still uses console.anthropic.com + claude.ai/oauth/authorize, which claude.ai now rejects
// ("Invalid request format"); these match Claude Code 2.1.322's own config.
let claudeRedirect = "https://platform.claude.com/oauth/code/callback"
let claudeUA = "claude-cli/2.1.280 (external, cli)" // exact string in the original snapshot (ev_ffa8cb30)
let codexClient = "app_EMoamEEZ73f0CkXaXp7hrann"
let codexRedirect = "http://localhost:1455/auth/callback"
let grokClient = "xai-grok-cli"
let loopback22255 = "http://localhost:22255/auth/callback"
let googleClient = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"

func authorizeURL(_ k: Kind, verifier: String, state: String) -> URL {
    let base: String, extra: [(String, String)]
    switch k {
    case .claude:
        base = "https://claude.com/cai/oauth/authorize"
        extra = [("code", "true"), ("client_id", claudeClient), ("redirect_uri", claudeRedirect),
                 ("scope", "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload user:plugins")]
    case .codex:
        base = "https://auth.openai.com/oauth/authorize"
        extra = [("client_id", codexClient), ("redirect_uri", codexRedirect), ("scope", "openid profile email offline_access"),
                 ("id_token_add_organizations", "true"), ("codex_cli_simplified_flow", "true"), ("originator", "codex_cli_rs")]
    case .grok:
        base = "https://auth.x.ai/oauth2/authorize"
        extra = [("client_id", grokClient), ("redirect_uri", loopback22255),
                 ("scope", "openid profile offline_access grok-cli:access api:access")]
    case .antigravity:
        base = "https://accounts.google.com/o/oauth2/v2/auth"
        extra = [("client_id", googleClient), ("redirect_uri", loopback22255), ("access_type", "offline"), ("prompt", "consent"),
                 ("scope", "openid https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email")]
    }
    var c = URLComponents(string: base)!
    c.queryItems = (extra + [("response_type", "code"), ("code_challenge", challenge(verifier)),
                             ("code_challenge_method", "S256"), ("state", state)]).map(URLQueryItem.init)
    return c.url!
}

/// Token endpoint call for both code exchange (`code` set) and refresh.
func tokenCall(_ k: Kind, code: String? = nil, verifier: String = "", state: String = "", refresh: String = "") async throws -> [String: Any] {
    var f: [String: String] = code.map { ["grant_type": "authorization_code", "code": $0, "code_verifier": verifier] }
        ?? ["grant_type": "refresh_token", "refresh_token": refresh]
    switch k {
    case .claude:
        f["client_id"] = claudeClient
        if code != nil { f["redirect_uri"] = claudeRedirect; f["state"] = state }
        return try await request("https://platform.claude.com/v1/oauth/token", method: "POST", headers: ["User-Agent": claudeUA], json: f)
    case .codex:
        f["client_id"] = codexClient
        if code != nil { f["redirect_uri"] = codexRedirect; return try await request("https://auth.openai.com/oauth/token", method: "POST", form: f) }
        f["scope"] = "openid profile email"
        return try await request("https://auth.openai.com/oauth/token", method: "POST", json: f)
    case .grok:
        f["client_id"] = grokClient
        if code != nil { f["redirect_uri"] = loopback22255 }
        return try await request("https://auth.x.ai/oauth2/token", method: "POST", form: f)
    case .antigravity:
        f["client_id"] = googleClient; f["client_secret"] = antigravitySecret
        if code != nil { f["redirect_uri"] = loopback22255 }
        return try await request("https://oauth2.googleapis.com/token", method: "POST", form: f)
    }
}

func makeAccount(_ k: Kind, _ j: [String: Any], old: Account? = nil) async throws -> Account {
    guard let at = j["access_token"] as? String else { throw Fail("토큰 응답 이상") }
    let idt = jwt(j["id_token"] as? String)
    var extra = old?.extra ?? [:]
    if k == .codex, let a = ((idt["https://api.openai.com/auth"] ?? jwt(at)["https://api.openai.com/auth"]) as? [String: Any])?["chatgpt_account_id"] as? String {
        extra["account_id"] = a
    }
    var label = old?.label
    if label == nil {
        switch k {
        case .claude: label = (j["account"] as? [String: Any])?["email_address"] as? String
        case .antigravity:
            label = (try? await request("https://www.googleapis.com/oauth2/v2/userinfo?alt=json",
                                        headers: ["Authorization": "Bearer \(at)"]))?["email"] as? String
        default: label = (idt["email"] ?? jwt(at)["email"]) as? String
        }
    }
    let exp = num(j["expires_in"]).map { Date().addingTimeInterval($0) }
        ?? num(jwt(at)["exp"]).map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(3600)
    return Account(kind: k, label: label ?? "\(k.title) \(Int.random(in: 100...999))", access: at,
                   refresh: j["refresh_token"] as? String ?? old?.refresh ?? "", expires: exp, extra: extra)
}

// MARK: - Usage fetchers

struct Usage { var wins: [Win]; var note: String? = nil; var redeemable = false }

func fetchUsage(_ a: Account) async throws -> Usage {
    switch a.kind {
    case .claude: return try await claudeUsage(a.access)
    case .codex: return try await codexUsage(a.access, accountId: a.extra["account_id"])
    case .grok: return try await grokUsage(a.access)
    case .antigravity: return try await antigravityUsage(a)
    }
}

func claudeUsage(_ token: String) async throws -> Usage {
    let j = try await request("https://api.anthropic.com/api/oauth/usage",
                              headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": claudeUA])
    let keys = [("five_hour", "5시간"), ("seven_day", "주간"), ("seven_day_opus", "주간 Opus"), ("seven_day_sonnet", "주간 Sonnet"),
                ("seven_day_fable", "주간 Fable"), ("seven_day_oauth_apps", "주간 OAuth 앱")]
    let wins = keys.compactMap { k, name -> Win? in
        guard let w = j[k] as? [String: Any], let u = num(w["utilization"]) else { return nil }
        return Win(name: name, used: u, reset: date(w["resets_at"]))
    }
    // reset credits: field names from the snapshot; Claude's redeem endpoint is not in it, so display only
    let left = num(find("resets_left", in: j["usage_limit_resets"] ?? j["rate_limit_resets"]))
    return Usage(wins: wins, note: left.map { "리셋 크레딧 \(Int($0))개" })
}

func codexUsage(_ token: String, accountId: String?) async throws -> Usage {
    var h = ["Authorization": "Bearer \(token)", "User-Agent": "codex_cli_rs"]
    if let accountId { h["chatgpt-account-id"] = accountId }
    let j = try await request("https://chatgpt.com/backend-api/wham/usage", headers: h)
    let rl = j["rate_limit"] as? [String: Any] ?? [:]
    let wins = ["primary_window", "secondary_window"].compactMap { k -> Win? in
        guard let w = rl[k] as? [String: Any], let u = num(w["used_percent"]) else { return nil }
        let hrs = Int(num(w["limit_window_seconds"]) ?? 0) / 3600
        let reset = date(w["reset_at"]) ?? num(w["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
        return Win(name: hrs >= 24 ? "주간" : "\(hrs)시간", used: u, reset: reset)
    }
    let rc = j["rate_limit_reset_credits"] as? [String: Any]
    let avail = Int(num(rc?["available_count"]) ?? 0), now = Int(num(rc?["applicable_available_count"]) ?? 0)
    return Usage(wins: wins, note: rc == nil ? nil : "리셋 크레딧 \(avail)개 (지금 사용 가능 \(now))", redeemable: now > 0)
}

// ponytail: consume body is not recoverable from the AOT snapshot; sends the credit_id the list endpoint returns.
func redeemCodexReset(_ a: Account) async throws {
    var h = ["Authorization": "Bearer \(a.access)", "User-Agent": "codex_cli_rs"]
    if let id = a.extra["account_id"] { h["chatgpt-account-id"] = id }
    let list = try await request("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: h)
    let id = find("credit_id", in: list) ?? find("id", in: list)
    _ = try await request("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume", method: "POST", headers: h,
                          json: id.map { ["credit_id": $0] } ?? [:])
}

// ponytail: Grok's response shape is unverified; reads the field names found in the snapshot wherever they sit.
func grokUsage(_ token: String) async throws -> Usage {
    let j = try await request("https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: ["Authorization": "Bearer \(token)"])
    let pct = num(find("creditUsagePercent", in: j)) ?? num(find("usagePercent", in: j))
        ?? zip2(num(find("totalUsed", in: j)), num(find("monthlyLimit", in: j))).map { $1 > 0 ? $0 / $1 * 100 : 0 }
    guard let pct else { throw Fail("Grok 응답 형식을 읽지 못함 (--dump로 확인)") }
    let reset = date(find("resetAt", in: j) ?? find("periodEnd", in: j) ?? find("currentPeriodEnd", in: j))
    return Usage(wins: [Win(name: "월간 크레딧", used: pct, reset: reset)])
}
func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? { a.flatMap { a in b.map { (a, $0) } } }

func antigravityUsage(_ a: Account) async throws -> Usage {
    let h = ["Authorization": "Bearer \(a.access)", "User-Agent": "antigravity"]
    let base = "https://cloudcode-pa.googleapis.com/v1internal"
    let load = try await request("\(base):loadCodeAssist", method: "POST", headers: h, json: ["metadata": ["ideType": "ANTIGRAVITY"]])
    let project = (load["cloudaicompanionProject"] as? String) ?? ((load["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)
    let j = try await request("\(base):fetchAvailableModels", method: "POST", headers: h, json: project.map { ["project": $0] } ?? [:])
    // group like the original ("gemini" / "claude_gpt" families): the lowest remaining in each family
    var fam: [String: (Double, Date?)] = [:]
    for (name, v) in j["models"] as? [String: Any] ?? [:] {
        guard let q = (v as? [String: Any])?["quotaInfo"] as? [String: Any] else { continue }
        let used = (1 - (num(q["remainingFraction"]) ?? 1)) * 100
        let f = name.contains("gemini") ? "Gemini 모델" : "Claude·GPT 모델"
        if used >= fam[f]?.0 ?? -1 { fam[f] = (used, date(q["resetTime"])) }
    }
    guard !fam.isEmpty else { throw Fail("Antigravity 모델 쿼터 없음") }
    return Usage(wins: fam.sorted { $0.key < $1.key }.map { Win(name: $0.key, used: $0.value.0, reset: $0.value.1) })
}

// Codex CLI login as a fallback when no Codex account is connected in-app.
func codexCLIAccount() -> Account? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    guard let d = try? Data(contentsOf: url), let t = json(d)["tokens"] as? [String: Any],
          let at = t["access_token"] as? String else { return nil }
    return Account(kind: .codex, label: "CLI", access: at, refresh: "", expires: .distantFuture,
                   extra: (t["account_id"] as? String).map { ["account_id": $0] } ?? [:])
}
