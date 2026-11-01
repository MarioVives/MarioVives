// ClaudeTokens : petite app de barre de menus macOS qui affiche
// la consommation de tokens de Claude Code, lue dans les logs locaux
// (~/.claude/projects/**/*.jsonl). Aucune clé API, aucun réseau.

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Limites du plan (estimation locale, sans réseau)
//
// Anthropic n'expose le "% de plan utilisé" que via l'app officielle
// (appel réseau authentifié). Pour l'estimer sans réseau, on pondère les
// tokens locaux par un poids approximatif de coût (cf. grille tarifaire
// Anthropic : sortie ≈ 5x entrée, écriture cache ≈ 1.25x, lecture cache
// ≈ 0.1x), puis on divise par un "budget" calibré une fois en comparant
// cette somme pondérée à la vraie valeur lue dans l'app officielle.
//
// Calibré le 1 nov. 2026. À recalibrer de temps en temps (la calibration
// hebdomadaire initiale est faite sur un seul pic d'usage, donc fragile) :
// relire le % réel dans l'app, comparer à la somme pondérée locale sur la
// même fenêtre, et ajuster les constantes ci-dessous.
enum PlanBudget {
    static let weightInput = 1.0
    static let weightOutput = 5.0
    static let weightCacheWrite = 1.25
    static let weightCacheRead = 0.1

    static let fiveHourUnits = 42_390_577.0
    static let weeklyUnits = 30_278_984.0
    static let calibratedAt = "1 nov. 2026"

    /// Le repère hebdomadaire observé deux fois à la même heure (vendredi
    /// 05:00 UTC) : on suppose qu'il est fixe pour ce compte.
    static let weeklyResetWeekday = 6 // 1 = dimanche ... 6 = vendredi
    static let weeklyResetHourUTC = 5

    static func mostRecentWeeklyReset(from now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        comps.weekday = weeklyResetWeekday
        comps.hour = weeklyResetHourUTC
        comps.minute = 0
        comps.second = 0
        guard let candidate = cal.date(from: comps) else { return now }
        return candidate <= now ? candidate : cal.date(byAdding: .day, value: -7, to: candidate)!
    }
}

// MARK: - Modèle

struct TokenUsage: Sendable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite += rhs.cacheWrite
        lhs.cacheRead += rhs.cacheRead
    }
}

struct UsageEntry: Sendable {
    let key: String      // message.id + requestId, pour dédoublonner
    let date: Date
    let model: String
    let project: String
    let usage: TokenUsage
}

struct NamedUsage: Sendable, Identifiable {
    let name: String
    let usage: TokenUsage
    var id: String { name }
}

struct DayTotal: Sendable, Identifiable {
    let day: Date
    let total: Int
    var id: Date { day }
}

struct Summary: Sendable {
    var today = TokenUsage()
    var week = TokenUsage()
    var month = TokenUsage()
    var todayByModel: [NamedUsage] = []
    var monthByProject: [NamedUsage] = []
    var last7Days: [DayTotal] = []
    var fileCount = 0

    // Estimation locale des limites de plan (voir PlanBudget).
    var fiveHourPercent: Double = 0
    var weekPercent: Double = 0
    var weekResetsAt: Date = Date()
}

// MARK: - Lecture des logs

enum LogParser {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let usageMarker = Data("\"usage\"".utf8)

    static func parse(fileAt url: URL) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let fallbackProject = url.deletingLastPathComponent().lastPathComponent
        var result: [UsageEntry] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Filtre rapide avant de décoder le JSON.
            guard line.range(of: usageMarker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = isoFrac.date(from: ts) ?? iso.date(from: ts)
            else { continue }

            let model = message["model"] as? String ?? "inconnu"
            if model == "<synthetic>" { continue }

            func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let u = TokenUsage(
                input: int("input_tokens"),
                output: int("output_tokens"),
                cacheWrite: int("cache_creation_input_tokens"),
                cacheRead: int("cache_read_input_tokens")
            )
            if u.total == 0 { continue }

            let msgId = message["id"] as? String ?? ""
            let reqId = obj["requestId"] as? String ?? ""
            let key = (msgId.isEmpty && reqId.isEmpty) ? UUID().uuidString : "\(msgId):\(reqId)"

            let project: String
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                project = URL(fileURLWithPath: cwd).lastPathComponent
            } else {
                project = fallbackProject
            }

            result.append(UsageEntry(key: key, date: date, model: model, project: project, usage: u))
        }
        return result
    }
}

actor UsageScanner {
    private struct CachedFile {
        let mtime: Date
        let size: Int
        let entries: [UsageEntry]
    }

    private var cache: [String: CachedFile] = [:]

    private let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".config/claude/projects"),
        ]
    }()

    func scan(now: Date = Date()) -> Summary {
        let fm = FileManager.default
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let start7 = cal.date(byAdding: .day, value: -6, to: startToday)!
        let start30 = cal.date(byAdding: .day, value: -29, to: startToday)!
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        var all: [UsageEntry] = []
        var seenPaths = Set<String>()

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true,
                      let mtime = v.contentModificationDate,
                      mtime >= start30 // fichier pas touché depuis 30 jours : inutile
                else { continue }
                let size = v.fileSize ?? 0
                let path = url.path
                seenPaths.insert(path)

                if let c = cache[path], c.mtime == mtime, c.size == size {
                    all.append(contentsOf: c.entries)
                } else {
                    let entries = LogParser.parse(fileAt: url)
                    cache[path] = CachedFile(mtime: mtime, size: size, entries: entries)
                    all.append(contentsOf: entries)
                }
            }
        }
        cache = cache.filter { seenPaths.contains($0.key) }

        // Agrégation (avec dédoublonnage : un même message peut apparaître
        // sur plusieurs lignes ou dans plusieurs sessions reprises).
        var s = Summary()
        s.fileCount = seenPaths.count
        var seen = Set<String>()
        var byModel: [String: TokenUsage] = [:]
        var byProject: [String: TokenUsage] = [:]
        var daily: [Date: Int] = [:]

        for e in all where e.date >= start30 {
            guard seen.insert(e.key).inserted else { continue }
            s.month += e.usage
            byProject[e.project, default: TokenUsage()] += e.usage
            if e.date >= start7 {
                s.week += e.usage
                daily[cal.startOfDay(for: e.date), default: 0] += e.usage.total
            }
            if e.date >= startToday {
                s.today += e.usage
                byModel[Fmt.model(e.model), default: TokenUsage()] += e.usage
            }
        }

        s.todayByModel = byModel
            .sorted { $0.value.total > $1.value.total }
            .map { NamedUsage(name: $0.key, usage: $0.value) }
        s.monthByProject = byProject
            .sorted { $0.value.total > $1.value.total }
            .prefix(5)
            .map { NamedUsage(name: $0.key, usage: $0.value) }
        s.last7Days = (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start7)!
            return DayTotal(day: d, total: daily[d] ?? 0)
        }

        // Estimation locale du % de plan utilisé (fenêtre 5h glissante +
        // semaine calée sur le dernier repère de reset connu).
        let fiveHStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = PlanBudget.mostRecentWeeklyReset(from: now)
        func weighted(_ u: TokenUsage) -> Double {
            Double(u.input) * PlanBudget.weightInput
                + Double(u.output) * PlanBudget.weightOutput
                + Double(u.cacheWrite) * PlanBudget.weightCacheWrite
                + Double(u.cacheRead) * PlanBudget.weightCacheRead
        }
        var seen5h = Set<String>()
        var seenWeek = Set<String>()
        var units5h = 0.0
        var unitsWeek = 0.0
        for e in all {
            let w = weighted(e.usage)
            if e.date >= fiveHStart, seen5h.insert(e.key).inserted {
                units5h += w
            }
            if e.date >= weekStart, seenWeek.insert(e.key).inserted {
                unitsWeek += w
            }
        }
        s.fiveHourPercent = units5h / PlanBudget.fiveHourUnits * 100
        s.weekPercent = unitsWeek / PlanBudget.weeklyUnits * 100
        s.weekResetsAt = weekStart.addingTimeInterval(7 * 24 * 3600)

        return s
    }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var summary = Summary()
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let scanner = UsageScanner()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let s = await scanner.scan()
            self.summary = s
            self.lastUpdate = Date()
            self.isRefreshing = false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Formatage

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...: return String(format: "%.1f Md", d / 1e9)
        case 1_000_000...: return String(format: "%.1f M", d / 1e6)
        case 10_000...: return String(format: "%.0f k", d / 1e3)
        case 1_000...: return String(format: "%.1f k", d / 1e3)
        default: return "\(n)"
        }
    }

    /// "claude-sonnet-4-5-20250929" -> "sonnet-4-5"
    static func model(_ raw: String) -> String {
        var m = raw
        if m.hasPrefix("claude-") { m.removeFirst("claude-".count) }
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m
    }

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE 'à' HH:mm"
        return f
    }()

    static func percent(_ p: Double) -> String {
        String(format: "%.0f %%", p)
    }
}

// MARK: - Vues

struct StatTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.tokens(value)).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

struct DailyBars: View {
    let days: [DayTotal]

    var body: some View {
        let maxValue = max(days.map(\.total).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { d in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(Calendar.current.isDateInToday(d.day) ? 1 : 0.55))
                        .frame(height: max(2, 56 * CGFloat(d.total) / CGFloat(maxValue)))
                        .help("\(Fmt.weekday.string(from: d.day)) : \(Fmt.tokens(d.total))")
                    Text(Fmt.weekday.string(from: d.day))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 74, alignment: .bottom)
    }
}

struct Row: View {
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Text(label).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Fmt.tokens(value)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Bleu en dessous de 70 %, orange entre 70 et 90, rouge au-delà.
func planLimitColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .accentColor
}

struct PlanLimitRow: View {
    let label: String
    let percent: Double
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(Fmt.percent(percent))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(percent >= 90 ? Color.red : Color.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(planLimitColor(percent))
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(percent, 0), 100) / 100)))
                }
            }
            .frame(height: 7)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct InfoBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

/// Bascule à deux segments façon contrôle segmenté macOS (fond clair,
/// pastille blanche avec ombre portée sur le segment sélectionné).
struct SegmentedToggle: View {
    @Binding var selection: String
    let options: [(key: String, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.key) { option in
                let isSelected = option.key == selection
                Button {
                    selection = option.key
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear)
                        .shadow(color: .black.opacity(isSelected ? 0.18 : 0), radius: 2, y: 1)
                )
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
    }
}

/// Switch façon macOS pour remplacer le Toggle natif dans le pied du popover.
struct SwitchView: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 10)
                .fill(isOn ? Color.green : Color.primary.opacity(0.12))
                .frame(width: 34, height: 20)
                .overlay(
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                )
        }
        .buttonStyle(.plain)
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("ct.popoverMode") private var mode: String = "percent"

    var body: some View {
        let s = store.summary
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 20, height: 20)
                    .overlay(Text("✦").font(.system(size: 11)).foregroundStyle(.white))
                Text("Claude Tokens").font(.headline)
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Rafraîchir")
            }

            if s.fileCount == 0 && store.lastUpdate != nil {
                Text("Aucun log Claude Code récent trouvé dans ~/.claude/projects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                SegmentedToggle(selection: $mode, options: [("percent", "% du plan"), ("tokens", "Tokens")])

                if mode == "percent" {
                    InfoSection(title: "Limites du plan (estimation)") {
                        PlanLimitRow(
                            label: "5 dernières heures",
                            percent: s.fiveHourPercent,
                            detail: "Fenêtre glissante, pas un vrai compteur Anthropic"
                        )
                        PlanLimitRow(
                            label: "Cette semaine",
                            percent: s.weekPercent,
                            detail: "Réinitialisation \(Fmt.weekdayTime.string(from: s.weekResetsAt))"
                        )
                    }
                    InfoBanner(text: "Estimation locale, non officielle — calibrée le \(PlanBudget.calibratedAt).")
                } else {
                    HStack(spacing: 8) {
                        StatTile(title: "Aujourd'hui", value: s.today.total)
                        StatTile(title: "7 jours", value: s.week.total)
                        StatTile(title: "30 jours", value: s.month.total)
                    }

                    DailyBars(days: s.last7Days)

                    InfoSection(title: "Aujourd'hui, par type") {
                        Row(label: "Entrée", value: s.today.input)
                        Row(label: "Sortie", value: s.today.output)
                        Row(label: "Écriture cache", value: s.today.cacheWrite)
                        Row(label: "Lecture cache", value: s.today.cacheRead)
                    }

                    if !s.todayByModel.isEmpty {
                        InfoSection(title: "Aujourd'hui, par modèle") {
                            ForEach(s.todayByModel) { Row(label: $0.name, value: $0.usage.total) }
                        }
                    }

                    if !s.monthByProject.isEmpty {
                        InfoSection(title: "30 jours, top projets") {
                            ForEach(s.monthByProject) { Row(label: $0.name, value: $0.usage.total) }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("Lancer à l'ouverture de session").font(.callout)
                Spacer()
                SwitchView(isOn: store.launchAtLogin) {
                    store.setLaunchAtLogin(!store.launchAtLogin)
                }
            }

            HStack {
                if let t = store.lastUpdate {
                    Text("Mis à jour à \(Fmt.time.string(from: t))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - App

@main
struct ClaudeTokensApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsageView(store: store)
        } label: {
            Text("✦ " + Fmt.percent(store.summary.fiveHourPercent))
        }
        .menuBarExtraStyle(.window)
    }
}
