import SwiftUI
import Charts
import UserNotifications

struct Row: Identifiable {
    let account: Account
    var id: String { account.id }
    var title: String { "\(account.kind.title) · \(account.label)" }
    var wins: [Win] = []; var note: String?; var error: String?; var redeemable = false; var removable = true
}

struct Point: Codable { let t: Date; let remaining: Double }

let historyURL: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UseAI")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("history.json")
}()

final class NotiDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor final class Store: ObservableObject {
    @Published var rows: [Row] = []
    @Published var updated: Date?
    @Published var accounts = Vault.load()
    @Published var claudeLogin: (verifier: String, state: String)?
    @Published var pasted = ""
    @Published var status: String?
    @Published var report: [ModelTotal]?
    @Published var reportLoading = false
    @Published var history = (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([String: [Point]].self, from: $0) } ?? [:]
    @Published var threshold = UserDefaults.standard.object(forKey: "threshold") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }
    let notiDelegate = NotiDelegate()

    func refresh() async {
        var out: [Row] = []
        for a in accounts { out.append(await row(for: a, removable: true)) }
        if !accounts.contains(where: { $0.kind == .codex }), let cli = codexCLIAccount() { out.append(await row(for: cli, removable: false)) }
        for r in out where r.error == nil { for w in r.wins { checkAlerts(r, w) } }
        rows = out
        record()
        updated = Date()
    }

    private func row(for start: Account, removable: Bool) async -> Row {
        var a = start
        let old = rows.first { $0.id == a.id }
        do {
            if a.expires < Date().addingTimeInterval(60), !a.refresh.isEmpty {
                do { a = try await makeAccount(a.kind, tokenCall(a.kind, refresh: a.refresh), old: a) } catch { throw AuthExpired() }
                if let i = accounts.firstIndex(where: { $0.id == a.id }) { accounts[i] = a; Vault.save(accounts) }
            }
            let u = try await fetchUsage(a)
            fired.remove("auth|\(a.id)")
            return Row(account: a, wins: u.wins, note: u.note, redeemable: u.redeemable, removable: removable)
        } catch {
            if error is AuthExpired, fired.insert("auth|\(a.id)").inserted {
                notify("\(a.kind.title) 로그인 만료", "\(a.label) 계정을 다시 연결해야 사용량을 계속 볼 수 있어요.")
            }
            // keep last good numbers on failure (the Claude endpoint 429s easily)
            return Row(account: a, wins: old?.wins ?? [], note: old?.note, error: error.localizedDescription, removable: removable)
        }
    }

    // MARK: notifications: threshold, reset (early or on time), auth expiry

    private var fired = Set(UserDefaults.standard.stringArray(forKey: "fired") ?? []) {
        didSet { UserDefaults.standard.set(Array(fired.suffix(500)), forKey: "fired") }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func checkAlerts(_ r: Row, _ w: Win) {
        let left = Int((100 - w.used).rounded())
        let epoch = Int((w.reset?.timeIntervalSince1970 ?? 0) / 3600)
        if left <= threshold, fired.insert("low|\(r.id)|\(w.name)|\(epoch)").inserted {
            notify("\(r.title) \(w.name) 남은 \(left)%", w.reset.map { "리셋까지 \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))" } ?? "")
        }
        guard let prev = rows.first(where: { $0.id == r.id })?.wins.first(where: { $0.name == w.name }), prev.used - w.used >= 10 else { return }
        let early = prev.reset.map { Date() < $0.addingTimeInterval(-120) } ?? false
        notify("\(r.title) \(w.name) \(early ? "일찍 리셋됨" : "리셋됨")", "지금 남은 \(left)%")
    }

    // MARK: history (7 days)

    private func record() {
        let now = Date(), cutoff = now.addingTimeInterval(-7 * 86400)
        for r in rows where r.error == nil {
            for w in r.wins { history["\(r.id)|\(w.name)", default: []].append(Point(t: now, remaining: 100 - w.used)) }
        }
        history = history.mapValues { $0.filter { $0.t > cutoff } }.filter { !$0.value.isEmpty }
        try? JSONEncoder().encode(history).write(to: historyURL)
    }

    // MARK: accounts

    func startLogin(_ k: Kind) {
        let v = randomB64(32), s = randomB64(16), url = authorizeURL(k, verifier: v, state: s)
        status = nil
        if k == .claude { claudeLogin = (v, s); pasted = ""; NSWorkspace.shared.open(url); return }
        status = "\(k.title): 브라우저에서 로그인하세요…"
        Task {
            do {
                let q = try await waitForCallback(port: k == .codex ? 1455 : 22255) { NSWorkspace.shared.open(url) }
                guard q["state"] == s, let code = q["code"] else { throw Fail("잘못된 콜백") }
                let a = try await makeAccount(k, tokenCall(k, code: code, verifier: v, state: s))
                status = nil
                await add(a)
            } catch { status = "\(k.title) 연결 실패: \(error.localizedDescription)" }
        }
    }

    func finishClaude() async {
        guard let l = claudeLogin else { return }
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#").map(String.init)
        do {
            guard let code = parts.first, !code.isEmpty else { throw Fail("코드를 붙여넣으세요") }
            let a = try await makeAccount(.claude, tokenCall(.claude, code: code, verifier: l.verifier,
                                                              state: parts.count > 1 ? parts[1] : l.state))
            claudeLogin = nil; status = nil
            await add(a)
        } catch { status = "Claude 연결 실패: \(error.localizedDescription)" }
    }

    private func add(_ a: Account) async {
        accounts.removeAll { $0.id == a.id }; accounts.append(a); Vault.save(accounts)
        await refresh()
    }

    func remove(_ r: Row) {
        accounts.removeAll { $0.id == r.id }; Vault.save(accounts)
        rows.removeAll { $0.id == r.id }
    }

    func redeem(_ r: Row) async {
        do { try await redeemCodexReset(r.account); await refresh() } catch { status = "리셋 실패: \(error.localizedDescription)" }
    }

    func loadReport() async {
        reportLoading = true
        report = await Task.detached { monthReport() }.value
        reportLoading = false
    }

    var minRemaining: Int? { rows.flatMap(\.wins).map { Int((100 - $0.used).rounded()) }.min() }
}

struct RowView: View {
    @ObservedObject var store: Store
    let row: Row
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if row.removable {
                    Button { store.remove(row) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("계정 제거")
                }
            }
            if let e = row.error { Text(e).font(.caption).foregroundStyle(.secondary) }
            ForEach(row.wins) { w in
                HStack { Text(w.name); Spacer(); Text("남은 \(Int((100 - w.used).rounded()))%").monospacedDigit() }.font(.callout)
                ProgressView(value: min(max(w.used, 0), 100), total: 100)
                    .tint(w.used >= 90 ? .red : w.used >= 70 ? .orange : .accentColor)
                if let pts = store.history["\(row.id)|\(w.name)"], pts.count > 1 {
                    Chart(pts, id: \.t) { LineMark(x: .value("시간", $0.t), y: .value("남은 %", $0.remaining)) }
                        .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 26)
                        .help("최근 7일 남은 양")
                }
                if let r = w.reset { Text("리셋 \(r, style: .relative) 후").font(.caption2).foregroundStyle(.secondary) }
            }
            if let n = row.note {
                HStack {
                    Text(n).font(.caption).foregroundStyle(.secondary)
                    if row.redeemable { Button("지금 리셋") { Task { await store.redeem(row) } }.controlSize(.small) }
                }
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.rows) { RowView(store: store, row: $0) }
            if store.rows.isEmpty { Text("계정을 연결하세요").foregroundStyle(.secondary) }
            Divider()
            if store.claudeLogin != nil {
                Text("브라우저에서 승인 후 나온 코드를 붙여넣으세요").font(.caption)
                HStack {
                    TextField("code#state", text: $store.pasted).textFieldStyle(.roundedBorder)
                    Button("연결") { Task { await store.finishClaude() } }
                    Button("취소") { store.claudeLogin = nil }
                }
            } else {
                Menu("계정 추가") {
                    ForEach(Kind.allCases, id: \.self) { k in
                        Button(k.title) { store.startLogin(k) }.disabled(k == .antigravity && antigravitySecret.isEmpty)
                    }
                }.fixedSize()
            }
            if let s = store.status { Text(s).font(.caption).foregroundStyle(.secondary) }
            Stepper("남은 \(store.threshold)% 이하면 알림", value: $store.threshold, in: 0...100, step: 5).font(.callout)
            Divider()
            HStack {
                Text("이번 달 로컬 사용량").font(.headline)
                Spacer()
                Button(store.reportLoading ? "계산 중…" : "계산") { Task { await store.loadReport() } }
                    .controlSize(.small).disabled(store.reportLoading)
            }
            if let rep = store.report {
                ForEach(rep.prefix(8)) { m in
                    HStack {
                        Text("\(m.source) · \(m.model)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1fM", m.tokens / 1e6)).foregroundStyle(.secondary)
                        Text(m.cost.map { String(format: "$%.2f", $0) } ?? "–").frame(width: 64, alignment: .trailing)
                    }.font(.caption).monospacedDigit()
                }
                Text(String(format: "합계 API 환산 $%.2f", rep.compactMap(\.cost).reduce(0, +))).font(.caption.bold())
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
        .frame(width: 330)
    }
}

@main struct UseAIApp: App {
    @StateObject var store = Store()
    init() { // self-check: print this month's local report and quit
        guard CommandLine.arguments.contains("--report") else { return }
        for m in monthReport() { print(m.source, m.model, Int(m.tokens), m.cost.map { String(format: "$%.2f", $0) } ?? "unpriced") }
        exit(0)
    }
    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            Text(store.minRemaining.map { "AI \($0)%" } ?? "AI")
                .task {
                    UNUserNotificationCenter.current().delegate = store.notiDelegate
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                    while true { await store.refresh(); try? await Task.sleep(for: .seconds(300)) }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
