import AppKit
import ServiceManagement
import SwiftUI
import Charts
import Sparkle

let defaultIntervalMinutes = 15
let intervalRange = 1...240

let defaultPhrases = """
Какую задачу я решаю?
Что происходит?
"""

// MARK: - Оформление

/// Как выглядит всплывающая фраза. Хранится в настройках одним словарём.
struct Look {
    var fontSize: Double = 24
    var bold = true
    var textColor: NSColor?          // nil = автоматически под тему
    var tint: NSColor?               // цветная подложка поверх размытия, nil = нет
    var theme = 0                    // 0 как в системе, 1 тёмная, 2 светлая
    var cornerRadius: Double = 18
    var maxWidth: Double = 640
    var position = 0                 // 0 сверху, 1 по центру, 2 снизу

    static let fontRange = 12.0...64.0
    static let cornerRange = 0.0...40.0
    static let widthRange = 280.0...1200.0
    static let key = "look"

    static func load() -> Look {
        var l = Look()
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return l }
        if let v = d["fontSize"] as? Double { l.fontSize = v.clamped(fontRange) }
        if let v = d["bold"] as? Bool { l.bold = v }
        l.textColor = color(d["textColor"])
        l.tint = color(d["tint"])
        if let v = d["theme"] as? Int, (0...2).contains(v) { l.theme = v }
        if let v = d["cornerRadius"] as? Double { l.cornerRadius = v.clamped(cornerRange) }
        if let v = d["maxWidth"] as? Double { l.maxWidth = v.clamped(widthRange) }
        if let v = d["position"] as? Int, (0...2).contains(v) { l.position = v }
        return l
    }

    func save() {
        var d: [String: Any] = ["fontSize": fontSize, "bold": bold, "theme": theme,
                                "cornerRadius": cornerRadius, "maxWidth": maxWidth,
                                "position": position]
        if let c = textColor, let data = Look.data(c) { d["textColor"] = data }
        if let c = tint, let data = Look.data(c) { d["tint"] = data }
        UserDefaults.standard.set(d, forKey: Look.key)
    }

    var appearance: NSAppearance? {
        switch theme {
        case 1: return NSAppearance(named: .darkAqua)
        case 2: return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    private static func data(_ c: NSColor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true)
    }
    private static func color(_ v: Any?) -> NSColor? {
        (v as? Data).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0) }
    }
}

extension Comparable {
    func clamped(_ r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Оценка состояния

/// Настройки вопроса «оцени состояние».
struct RatingSettings {
    var every = 4                                  // каждый N-й показ вместо фразы
    var prompt = "Оцени своё состояние"

    static let everyRange = 1...20
    static let defaultPrompt = "Оцени своё состояние"
    static let key = "rating"

    static func load() -> RatingSettings {
        var r = RatingSettings()
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return r }
        if let v = d["every"] as? Int { r.every = v.clamped(everyRange) }
        if let v = d["prompt"] as? String { r.prompt = v }
        return r
    }

    func save() {
        UserDefaults.standard.set(["every": every, "prompt": prompt],
                                  forKey: RatingSettings.key)
    }
}

// MARK: - Режимы бытия

/// Набор фраз со своим ритмом показа: «Занятие», «Продажа». Обычный режим работает,
/// когда не включён никакой другой. Стиль плашки общий, он на вкладке «Показ».
struct BeingMode: Codable {
    var id: String                       // имя файла фраз, не меняется при переименовании
    var name: String
    var ordered = false                  // по списку по кругу, иначе вразнобой
    var intervalMinutes = defaultIntervalMinutes
    var seconds = 60                     // сколько держать на экране
    var askRating = true

    static let defaultID = "default"
    static let secondsRange = 3...600
    var isDefault: Bool { id == BeingMode.defaultID }

    var title: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Без названия" : t
    }

    /// Значения из настроек могли поправить руками: держим их в допустимых пределах.
    func clamped() -> BeingMode {
        var m = self
        m.intervalMinutes = intervalMinutes.clamped(intervalRange)
        m.seconds = seconds.clamped(BeingMode.secondsRange)
        return m
    }
}

/// Какой режим включён и до какого времени. until == nil — пока не выключат.
struct ActiveMode: Codable {
    var id: String
    var until: Date?
}

/// Сколько может длиться режим: пункты подменю, в минутах. nil — пока не выключат.
let modeDurations: [(title: String, minutes: Int?)] = [
    ("15 мин", 15), ("30 мин", 30), ("1 ч", 60), ("1,5 ч", 90), ("2 ч", 120), ("3 ч", 180),
    ("Пока не выключу", nil),
]

let sampleModePhrases = """
Кто сейчас молчит?
Задай вопрос группе
Проверь время
Говори медленнее
Что они должны унести с собой?
"""

/// Список режимов и включённый режим. Настройки в defaults, фразы — в текстовых файлах:
/// у обычного режима это прежний phrases.txt, у остальных modes/<id>.txt.
final class ModeStore {
    private(set) var modes: [BeingMode] = []
    private(set) var active: ActiveMode?
    private let dir: URL
    private static let modesKey = "modes", activeKey = "activeMode"

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("modes"),
                                                 withIntermediateDirectories: true)
        let base = url(BeingMode.defaultID)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? defaultPhrases.write(to: base, atomically: true, encoding: .utf8)
        }
        let d = UserDefaults.standard
        if let data = d.data(forKey: ModeStore.modesKey),
           let list = try? JSONDecoder().decode([BeingMode].self, from: data) {
            modes = list.map { $0.clamped() }
        } else {
            modes = ModeStore.firstLaunch()
            if !FileManager.default.fileExists(atPath: url(modes[1].id).path) {
                try? sampleModePhrases.write(to: url(modes[1].id), atomically: true, encoding: .utf8)
            }
            save()
        }
        if !modes.contains(where: \.isDefault) {
            modes.insert(BeingMode(id: BeingMode.defaultID, name: "Обычный"), at: 0)
            save()
        }
        if let data = d.data(forKey: ModeStore.activeKey),
           let a = try? JSONDecoder().decode(ActiveMode.self, from: data) {
            active = a
        }
        dropExpired()
    }

    /// До режимов интервал, время на экране и галочка оценки были общими.
    /// Теперь это настройки обычного режима. Рядом кладём образец «Занятие».
    private static func firstLaunch() -> [BeingMode] {
        let d = UserDefaults.standard
        var base = BeingMode(id: BeingMode.defaultID, name: "Обычный")
        let interval = d.integer(forKey: "intervalMinutes")
        if interval != 0 { base.intervalMinutes = interval }
        if let s = d.dictionary(forKey: Look.key)?["seconds"] as? Int { base.seconds = s }
        if let r = d.dictionary(forKey: RatingSettings.key)?["enabled"] as? Bool { base.askRating = r }
        let lesson = BeingMode(id: UUID().uuidString, name: "Занятие", ordered: false,
                               intervalMinutes: 10, seconds: 20, askRating: false)
        return [base.clamped(), lesson]
    }

    var current: BeingMode {
        active.flatMap { a in modes.first { $0.id == a.id } } ?? modes[0]
    }

    func mode(_ id: String) -> BeingMode? { modes.first { $0.id == id } }

    func update(_ id: String, _ change: (inout BeingMode) -> Void) {
        guard let i = modes.firstIndex(where: { $0.id == id }) else { return }
        change(&modes[i])
        modes[i] = modes[i].clamped()
        save()
    }

    /// Новый режим берёт ритм показа у обычного.
    func add() -> BeingMode {
        var m = modes[0]
        m.id = UUID().uuidString
        m.name = "Новый режим"
        modes.append(m)
        save()
        return m
    }

    /// Обычный режим удалить нельзя. Фразы удаляются вместе с режимом.
    func remove(_ id: String) {
        guard id != BeingMode.defaultID else { return }
        modes.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(id))
        if active?.id == id { setActive(nil) }
        save()
    }

    func setActive(_ a: ActiveMode?) {
        active = a?.id == BeingMode.defaultID ? nil : a
        if let a = active, let data = try? JSONEncoder().encode(a) {
            UserDefaults.standard.set(data, forKey: ModeStore.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ModeStore.activeKey)
        }
    }

    /// Время режима вышло или сам режим удалили. true — режим выключился.
    @discardableResult
    func dropExpired(now: Date = Date()) -> Bool {
        guard let a = active else { return false }
        guard mode(a.id) == nil || (a.until.map { $0 <= now } ?? false) else { return false }
        setActive(nil)
        return true
    }

    // MARK: Фразы

    func url(_ id: String) -> URL {
        id == BeingMode.defaultID ? dir.appendingPathComponent("phrases.txt")
                                  : dir.appendingPathComponent("modes/\(id).txt")
    }

    func phrasesText(_ id: String) -> String {
        (try? String(contentsOf: url(id), encoding: .utf8)) ?? ""
    }

    func savePhrases(_ text: String, _ id: String) throws {
        try text.write(to: url(id), atomically: true, encoding: .utf8)
    }

    func phrases(_ id: String) -> [String] {
        phrasesText(id).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(modes) {
            UserDefaults.standard.set(data, forKey: ModeStore.modesKey)
        }
    }
}

/// Пять звёзд, каждая делится пополам: значение от 1 до 10.
final class StarRating: NSView {
    var value = 0 { didSet { needsDisplay = true } }
    var starSize: CGFloat = 34 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private var hover: Int? { didSet { needsDisplay = true } }
    private var gap: CGFloat { starSize * 0.22 }

    override var intrinsicContentSize: NSSize { NSSize(width: starSize * 5 + gap * 4, height: starSize) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Левая половина звезды — нечётный балл, правая — чётный.
    private func points(at event: NSEvent) -> Int {
        let x = convert(event.locationInWindow, from: nil).x
        let step = starSize + gap
        let i = Int(x / step).clamped(0...4)
        let local = x - CGFloat(i) * step
        return i * 2 + (local < starSize / 2 ? 1 : 2)
    }

    override func mouseMoved(with event: NSEvent) { hover = points(at: event) }
    override func mouseExited(with event: NSEvent) { hover = nil }
    override func mouseDown(with event: NSEvent) {
        let v = points(at: event)
        value = v
        hover = nil
        onPick?(v)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shown = hover ?? value
        for i in 0..<5 {
            let rect = NSRect(x: CGFloat(i) * (starSize + gap), y: 0, width: starSize, height: starSize)
            let path = StarRating.star(in: rect)
            NSColor.tertiaryLabelColor.setFill()
            path.fill()
            let halves = (shown - i * 2).clamped(0...2)
            guard halves > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY,
                                      width: rect.width * CGFloat(halves) / 2, height: rect.height)).addClip()
            NSColor.systemYellow.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func star(in r: NSRect) -> NSBezierPath {
        let c = NSPoint(x: r.midX, y: r.midY - r.height * 0.03)
        let outer = r.width / 2, inner = outer * 0.42
        let path = NSBezierPath()
        for k in 0..<10 {
            let radius = k % 2 == 0 ? outer : inner
            let angle = CGFloat.pi / 2 + CGFloat(k) * CGFloat.pi / 5
            let p = NSPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
            if k == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Оценка от 1 до 10" }
    override func accessibilityValue() -> Any? { value }
}

/// Кнопка, которая срабатывает с первого клика в неактивном окне.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Статистика

struct RatingEntry: Identifiable {
    let id = UUID()
    let date: Date
    let points: Int
    let comment: String?
    let mode: String
}

/// Читает журнал оценок. Сам журнал по-прежнему CSV, окно только рисует его.
final class StatsModel: ObservableObject {
    @Published private(set) var entries: [RatingEntry] = []
    private let url: URL
    private let defaultMode: () -> String          // режим старых оценок, записанных до режимов

    init(url: URL, defaultMode: @escaping () -> String) {
        self.url = url
        self.defaultMode = defaultMode
        reload()
    }

    /// Строка CSV на поля: в кавычках могут быть запятые и удвоенные кавычки.
    static func fields(_ line: Substring) -> [String] {
        var out: [String] = [], cur = "", quoted = false, prev: Character?
        for ch in line {
            if ch == "\"" {
                if !quoted, prev == "\"" { cur.append(ch) }    // "" внутри кавычек — одна кавычка
                quoted.toggle()
            } else if ch == ",", !quoted {
                out.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
            prev = ch
        }
        out.append(cur)
        return out
    }

    func reload() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let base = defaultMode()
        entries = text.split(whereSeparator: \.isNewline).compactMap { line in
            // дата,оценка[,"комментарий"[,"режим"]]
            let parts = StatsModel.fields(line)
            guard parts.count >= 2, let date = f.date(from: parts[0]),
                  let p = Int(parts[1].trimmingCharacters(in: .whitespaces)), (1...10).contains(p) else { return nil }
            let comment = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let mode = parts.count > 3 && !parts[3].isEmpty ? parts[3] : base
            return RatingEntry(date: date, points: p, comment: comment, mode: mode)
        }.sorted { $0.date < $1.date }
    }
}

enum StatsPeriod: String, CaseIterable, Identifiable {
    case day = "День", week = "Неделя", month = "Месяц", all = "Всё"
    var id: Self { self }

    var start: Date? {
        let now = Date()
        switch self {
        case .day: return now.addingTimeInterval(-24 * 3600)
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .all: return nil
        }
    }
}

/// Точка на графике: отдельная оценка (за день) или среднее за сутки (за период длиннее).
struct StatPoint: Identifiable {
    let date: Date
    let value: Double
    let count: Int
    let comments: [String]
    let modes: [String]
    var id: Date { date }
}

struct StatsView: View {
    @ObservedObject var model: StatsModel
    var onOpenCSV: () -> Void
    @State private var period: StatsPeriod
    @State private var selected: Date?

    init(model: StatsModel, onOpenCSV: @escaping () -> Void,
         period: StatsPeriod = .week, selected: Date? = nil) {
        self.model = model
        self.onOpenCSV = onOpenCSV
        _period = State(initialValue: period)
        _selected = State(initialValue: selected)
    }

    private var filtered: [RatingEntry] {
        guard let start = period.start else { return model.entries }
        return model.entries.filter { $0.date >= start }
    }

    private var isDaily: Bool { period != .day }

    private var points: [StatPoint] {
        if !isDaily {
            return filtered.map { StatPoint(date: $0.date, value: Double($0.points), count: 1,
                                            comments: $0.comment.map { [$0] } ?? [], modes: [$0.mode]) }
        }
        let byDay = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
        return byDay.map { day, items in
            StatPoint(date: day, value: Double(items.map(\.points).reduce(0, +)) / Double(items.count),
                      count: items.count, comments: items.compactMap(\.comment),
                      modes: items.map(\.mode).reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
        }.sorted { $0.date < $1.date }
    }

    private var nearest: StatPoint? {
        guard let s = selected else { return nil }
        return points.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) }
    }

    private static let ru = Locale(identifier: "ru_RU")    // приложение целиком на русском

    private func score(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)).locale(StatsView.ru))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Период", selection: $period) {
                ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            HStack(spacing: 32) {
                tile("Среднее", filtered.isEmpty ? "—"
                     : score(Double(filtered.map(\.points).reduce(0, +)) / Double(filtered.count)))
                tile("Оценок", "\(filtered.count)")
                tile("Последняя", filtered.last.map { "\($0.points)" } ?? "—")
            }

            if points.isEmpty {
                VStack(spacing: 6) {
                    Text("За этот период оценок нет").font(.headline)
                    Text("Они появятся после ответов на вопрос «Оцени своё состояние».")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }

            HStack {
                Text(isDaily ? "Точка — среднее за день." : "Точка — одна оценка.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Открыть CSV", action: onOpenCSV).buttonStyle(.link).font(.caption)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 400)
        .environment(\.locale, StatsView.ru)
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Время", p.date), y: .value("Оценка", p.value))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Время", p.date), y: .value("Оценка", p.value))
                    .symbolSize(60)
            }
            if let p = nearest {
                RuleMark(x: .value("Время", p.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(p)
                    }
            }
        }
        .chartYScale(domain: 0...10)
        .chartXScale(range: .plotDimension(padding: 28))   // подписям у краёв хватает места
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 2, 4, 6, 8, 10]) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $selected)
        .padding(.top, 36)                       // место под подсказку над графиком
    }

    private func tooltip(_ p: StatPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isDaily ? p.date.formatted(.dateTime.weekday(.abbreviated).day().month().locale(StatsView.ru))
                         : p.date.formatted(.dateTime.day().month().hour().minute().locale(StatsView.ru)))
                .font(.caption).foregroundStyle(.secondary)
            Text("\(score(p.value)) из 10").font(.callout.weight(.semibold)).monospacedDigit()
            if isDaily {
                Text("среднее из \(p.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text(p.modes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ForEach(Array(p.comments.suffix(3).enumerated()), id: \.offset) { _, c in
                Text("«\(c)»").font(.caption).lineLimit(2)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
        }
    }
}

// MARK: - Всплывающее окно

/// Панель без рамки по умолчанию не принимает ввод с клавиатуры, эта — может.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum BubbleContent {
    case phrase(String)
    case rating(String)
}

final class Bubble: NSObject, NSTextFieldDelegate {
    /// Оценка, когда она её поставили, и необязательный комментарий.
    var onRate: ((Int, Date, String?) -> Void)?

    private enum Mode { case phrase, rating, comment }

    private var panel: KeyablePanel?
    private let effect = NSVisualEffectView()
    private let tintView = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let stars = StarRating()
    private let skip = FirstMouseButton()
    private var skipTop: NSLayoutConstraint!, skipTrailing: NSLayoutConstraint!
    private let commentField = NSTextField()
    private let mic = FirstMouseButton()
    private lazy var commentRow = NSStackView(views: [commentField, mic])
    private var commentWidth: NSLayoutConstraint!
    private var pending: (points: Int, date: Date)?   // оценка ждёт, допишут ли комментарий
    private let stack = NSStackView()
    private var click: NSClickGestureRecognizer!
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false
    private var look = Look()
    private var seconds = 60                           // сколько держать текущий показ
    private let padH: CGFloat = 32, padV: CGFloat = 22

    override init() {
        super.init()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center

        // Крестик закрытия в правом верхнем углу, как у обычных окон.
        skip.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Пропустить")
        skip.isBordered = false
        skip.contentTintColor = .tertiaryLabelColor
        skip.toolTip = "Пропустить"
        skip.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        skip.translatesAutoresizingMaskIntoConstraints = false
        skip.target = self
        skip.action = #selector(hide)
        stars.onPick = { [weak self] in self?.picked($0) }

        commentField.placeholderString = "Почему? Enter — сохранить"
        commentField.font = .systemFont(ofSize: 14)
        commentField.bezelStyle = .roundedBezel
        commentField.delegate = self
        commentWidth = commentField.widthAnchor.constraint(equalToConstant: 320)
        commentWidth.isActive = true
        mic.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Диктовка")
        mic.isBordered = false
        mic.contentTintColor = .secondaryLabelColor
        mic.toolTip = "Надиктовать"
        mic.target = self
        mic.action = #selector(dictate)
        commentRow.spacing = 8

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        [label, stars, commentRow].forEach(stack.addArrangedSubview)

        effect.addSubview(tintView)
        effect.addSubview(stack)
        effect.addSubview(skip)
        skipTop = skip.topAnchor.constraint(equalTo: effect.topAnchor)
        skipTrailing = skip.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: effect.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: padH),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -padH),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: padV),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -padV),
            skipTop, skipTrailing,
        ])
        click = NSClickGestureRecognizer(target: self, action: #selector(hide))
        effect.addGestureRecognizer(click)

    }

    /// Каждый показ идёт в новом окне. Окно, прожившее долго, macOS однажды привязала
    /// к одному рабочему столу, и на остальных столах плашку перестало быть видно.
    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = .none                         // не попадать в трансляцию и запись экрана
        p.level = .screenSaver                        // выше обычных и полноэкранных окон
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false                   // не прятать, когда переключаешься между приложениями
        p.acceptsMouseMovedEvents = true
        p.becomesKeyOnlyIfNeeded = true               // клавиатуру забираем только для комментария
        return p
    }

    /// Показывает фразу или вопрос с оценкой. Если окно уже на экране, заменяет содержимое.
    func show(_ content: BubbleContent, look: Look, seconds: Int, animated: Bool) {
        self.seconds = seconds
        flush()
        switch content {
        case .phrase(let text):
            label.stringValue = text
            setMode(.phrase)
        case .rating(let prompt):
            label.stringValue = prompt
            stars.value = 0
            setMode(.rating)
        }
        present(look: look, animated: animated, hideAfter: TimeInterval(seconds))
    }

    /// Перерисовать то, что сейчас на экране, в новом оформлении. false — показывать нечего.
    func restyle(_ look: Look) -> Bool {
        guard isVisible else { return false }
        present(look: look, animated: false, hideAfter: TimeInterval(seconds))
        return true
    }

    private func setMode(_ mode: Mode) {
        stars.isHidden = mode != .rating
        skip.isHidden = mode != .rating
        commentRow.isHidden = mode != .comment
        click.isEnabled = mode == .phrase              // вопрос и комментарий кликом по фону не закрываются
    }

    /// Оценка уже поставлена одним кликом. Комментарий — по желанию: курсор сразу в поле,
    /// Enter сохраняет, Esc пропускает, без ввода плашка закроется сама.
    private func picked(_ points: Int) {
        pending = (points, Date())
        label.stringValue = "\(points) из 10"
        commentField.stringValue = ""
        setMode(.comment)
        present(look: look, animated: false, hideAfter: 10)
        panel?.makeKey()
        panel?.makeFirstResponder(commentField)
    }

    /// Сохранить оценку, если она ещё ждёт комментария.
    func flush() { commit(commentField.stringValue) }

    private func commit(_ comment: String?) {
        guard let p = pending else { return }
        pending = nil
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        onRate?(p.points, p.date, text.isEmpty ? nil : text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(commentField.stringValue)
        case #selector(NSResponder.cancelOperation(_:)):
            commit(nil)
        default:
            return false
        }
        hide()
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleHide(after: 30)                        // пока печатают, не закрываем
    }

    @objc private func dictate() {
        panel?.makeKey()
        panel?.makeFirstResponder(commentField)
        scheduleHide(after: 30)
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: self)
    }

    private func present(look: Look, animated: Bool, hideAfter: TimeInterval) {
        self.look = look
        hideWork?.cancel()

        // Окно на экране только перерисовываем, для нового показа берём новое окно.
        let reuse = isVisible && panel != nil
        if !reuse {
            if let old = panel {
                old.orderOut(nil)
                old.contentView = nil                 // содержимое переезжает в новое окно
            }
            panel = makePanel()
        }
        let p = panel!
        p.appearance = look.appearance
        let frame = layout(look)

        if reuse {
            p.setFrame(frame, display: true)
        } else {
            isVisible = true
            if animated {
                let dy: CGFloat = look.position == 2 ? -12 : 12
                p.setFrame(frame.offsetBy(dx: 0, dy: dy), display: false)
                p.alphaValue = 0
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    p.animator().alphaValue = 1
                    p.animator().setFrame(frame, display: true)
                }
            } else {
                p.setFrame(frame, display: true)
                p.alphaValue = 1
                p.orderFrontRegardless()
            }
        }
        p.invalidateShadow()
        scheduleHide(after: hideAfter)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc func hide() {
        hideWork?.cancel()
        flush()                                        // не терять оценку и начатый комментарий
        guard isVisible, let p = panel else { return }
        isVisible = false
        // Следующий показ всё равно возьмёт новое окно, так что это окно можно убирать без оглядки.
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }

    private func layout(_ look: Look) -> NSRect {
        label.font = .systemFont(ofSize: look.fontSize, weight: look.bold ? .semibold : .regular)
        label.textColor = look.textColor ?? .labelColor
        label.preferredMaxLayoutWidth = look.maxWidth - 2 * padH
        stars.starSize = CGFloat(look.fontSize * 1.4)
        commentWidth.constant = min(360, look.maxWidth - 2 * padH - 30)
        tintView.layer?.backgroundColor = look.tint?.cgColor
        let r = CGFloat(look.cornerRadius)
        tintView.layer?.cornerRadius = r
        let inset = max(10, r * 0.4)                   // чем круглее угол, тем дальше крестик от края
        skipTop.constant = inset
        skipTrailing.constant = -inset
        effect.maskImage = Bubble.mask(radius: r)
        effect.layoutSubtreeIfNeeded()
        let size = effect.fittingSize

        // На том экране, где сейчас курсор.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let y: CGFloat
        switch look.position {
        case 1: y = vf.midY - size.height / 2
        case 2: y = vf.minY + 48
        default: y = vf.maxY - size.height - 24
        }
        return NSRect(x: vf.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }

    private static func mask(radius r: CGFloat) -> NSImage? {
        guard r > 0 else { return nil }
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - Окно настроек

/// Обёртка, чтобы вешать замыкания на контролы AppKit.
final class Action: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate,
                            NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: AppDelegate
    let window: NSWindow
    private let text: NSTextView
    private var actions: [Action] = []
    private var syncs: [() -> Void] = []     // выставить контролы по текущим настройкам
    private let modeList = NSTableView()
    private let nameField = NSTextField()
    private let removeButton = NSButton()
    private let startButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var selectedID = BeingMode.defaultID
    private var selected: BeingMode { app.modes.mode(selectedID) ?? app.modes.modes[0] }

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        text = scroll.documentView as! NSTextView
        super.init()

        window.title = "График жизни"
        window.minSize = NSSize(width: 660, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        NSColorPanel.shared.showsAlpha = true

        // Вкладка «Режимы»: слева список, справа выбранный режим.
        let column = NSTableColumn(identifier: .init("name"))
        modeList.addTableColumn(column)
        modeList.headerView = nil
        modeList.rowHeight = 24
        modeList.allowsEmptySelection = false
        modeList.dataSource = self
        modeList.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = modeList
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        let addButton = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: nil, action: nil)
        addButton.toolTip = "Новый режим"
        bind(addButton) { [unowned self] in self.addMode() }
        removeButton.image = NSImage(named: NSImage.removeTemplateName)
        removeButton.toolTip = "Удалить режим"
        bind(removeButton) { [unowned self] in self.confirmRemove() }
        for b in [addButton, removeButton] {
            b.bezelStyle = .smallSquare
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let listButtons = row([addButton, removeButton])
        listButtons.spacing = 0

        nameField.delegate = self
        nameField.placeholderString = "Название режима"
        let hint = NSTextField(labelWithString: "Одна фраза на строку. Изменения сохраняются сами.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        scroll.borderType = .bezelBorder
        text.font = .systemFont(ofSize: 15)
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.delegate = self

        startButton.addItem(withTitle: "Включить")
        startButton.addItems(withTitles: modeDurations.map(\.title))
        bind(startButton) { [unowned self] in
            let i = self.startButton.indexOfSelectedItem - 1
            guard modeDurations.indices.contains(i) else { return }
            self.app.startMode(self.selectedID, minutes: modeDurations[i].minutes)
        }
        let modeGrid = NSGridView(views: [
            [label("Порядок"), popup(["Вразнобой", "По списку по кругу"],
                get: { [unowned self] in self.selected.ordered ? 1 : 0 },
                set: { [unowned self] v in self.app.updateMode(self.selectedID) { $0.ordered = v == 1 } })],
            [label("Показывать каждые"), numberRow(intervalRange, unit: "мин",
                get: { [unowned self] in self.selected.intervalMinutes },
                set: { [unowned self] v in self.app.updateMode(self.selectedID) { $0.intervalMinutes = v } })],
            [label("Держать на экране"), numberRow(BeingMode.secondsRange, unit: "сек",
                get: { [unowned self] in self.selected.seconds },
                set: { [unowned self] v in self.app.updateMode(self.selectedID) { $0.seconds = v } })],
            [NSGridCell.emptyContentView, checkbox("Спрашивать оценку состояния",
                get: { [unowned self] in self.selected.askRating },
                set: { [unowned self] v in self.app.updateMode(self.selectedID) { $0.askRating = v } })],
            [NSGridCell.emptyContentView, startButton],
        ])
        modeGrid.column(at: 0).xPlacement = .trailing
        modeGrid.rowAlignment = .none
        modeGrid.yPlacement = .center
        modeGrid.rowSpacing = 8
        modeGrid.columnSpacing = 10

        let modesView = NSView()
        for v in [listScroll, listButtons, nameField, hint, scroll, modeGrid] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            modesView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: modesView.topAnchor, constant: 12),
            listScroll.leadingAnchor.constraint(equalTo: modesView.leadingAnchor, constant: 16),
            listScroll.widthAnchor.constraint(equalToConstant: 180),
            listButtons.topAnchor.constraint(equalTo: listScroll.bottomAnchor, constant: -1),
            listButtons.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: modesView.bottomAnchor, constant: -14),

            nameField.topAnchor.constraint(equalTo: listScroll.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: modesView.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            modeGrid.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            modeGrid.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            modeGrid.bottomAnchor.constraint(equalTo: listButtons.bottomAnchor),
        ])

        // Вкладка «Показ»: стиль плашки, общий для всех режимов.
        let reset = NSButton(title: "Сбросить оформление", target: nil, action: nil)
        bind(reset) { [unowned self] in
            self.app.updateLook { $0 = Look() }
            self.syncs.forEach { $0() }
        }
        let grid = NSGridView(views: [
            [label("Положение"), popup(["Сверху", "По центру", "Снизу"],
                get: { [unowned self] in self.app.look.position },
                set: { [unowned self] v in self.app.updateLook { $0.position = v } })],
            [label("Тема"), popup(["Как в системе", "Тёмная", "Светлая"],
                get: { [unowned self] in self.app.look.theme },
                set: { [unowned self] v in self.app.updateLook { $0.theme = v } })],
            [label("Размер текста"), slider(Look.fontRange,
                get: { [unowned self] in self.app.look.fontSize },
                set: { [unowned self] v in self.app.updateLook { $0.fontSize = v } })],
            [NSGridCell.emptyContentView, checkbox("Жирный",
                get: { [unowned self] in self.app.look.bold },
                set: { [unowned self] v in self.app.updateLook { $0.bold = v } })],
            [label("Цвет текста"), colorRow(clearTitle: "Авто", placeholder: .labelColor,
                get: { [unowned self] in self.app.look.textColor },
                set: { [unowned self] c in self.app.updateLook { $0.textColor = c } })],
            [label("Подложка"), colorRow(clearTitle: "Без цвета", placeholder: .clear,
                get: { [unowned self] in self.app.look.tint },
                set: { [unowned self] c in self.app.updateLook { $0.tint = c } })],
            [label("Скругление"), slider(Look.cornerRange,
                get: { [unowned self] in self.app.look.cornerRadius },
                set: { [unowned self] v in self.app.updateLook { $0.cornerRadius = v } })],
            [label("Ширина"), slider(Look.widthRange,
                get: { [unowned self] in self.app.look.maxWidth },
                set: { [unowned self] v in self.app.updateLook { $0.maxWidth = v } })],
            [NSGridCell.emptyContentView, reset],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        grid.yPlacement = .center
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let lookView = NSView()
        lookView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: lookView.topAnchor, constant: 16),
            grid.centerXAnchor.constraint(equalTo: lookView.centerXAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: lookView.bottomAnchor, constant: -12),
        ])

        // Вкладка «Оценка»
        let promptField = NSTextField()
        promptField.placeholderString = RatingSettings.defaultPrompt
        promptField.cell?.sendsActionOnEndEditing = true
        promptField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        bind(promptField) { [unowned self] in self.app.updateRating { $0.prompt = promptField.stringValue } }
        syncs.append { [unowned self] in promptField.stringValue = self.app.rating.prompt }
        let rateNow = NSButton(title: "Спросить сейчас", target: nil, action: nil)
        bind(rateNow) { [unowned self] in self.app.showRating() }
        let openLog = NSButton(title: "Статистика", target: nil, action: nil)
        bind(openLog) { [unowned self] in self.app.openStats() }
        let ratingHint = NSTextField(wrappingLabelWithString:
            "Вместо фразы появится вопрос и пять звёзд. Левая половина звезды — нечётный балл, правая — чётный, всего до 10. Спрашивать ли оценку, задаётся в каждом режиме. Ответы видны на графике в окне «Статистика».")
        ratingHint.font = .systemFont(ofSize: 12)
        ratingHint.textColor = .secondaryLabelColor
        ratingHint.preferredMaxLayoutWidth = 380
        let ratingGrid = NSGridView(views: [
            [label("Частота"), numberRow(RatingSettings.everyRange, prefix: "каждый", unit: "-й показ",
                get: { [unowned self] in self.app.rating.every },
                set: { [unowned self] v in self.app.updateRating { $0.every = v } })],
            [label("Вопрос"), promptField],
            [NSGridCell.emptyContentView, row([rateNow, openLog])],
            [NSGridCell.emptyContentView, ratingHint],
        ])
        ratingGrid.column(at: 0).xPlacement = .trailing
        ratingGrid.rowAlignment = .none
        ratingGrid.yPlacement = .center
        ratingGrid.rowSpacing = 10
        ratingGrid.columnSpacing = 10
        ratingGrid.translatesAutoresizingMaskIntoConstraints = false
        let ratingView = NSView()
        ratingView.addSubview(ratingGrid)
        NSLayoutConstraint.activate([
            ratingGrid.topAnchor.constraint(equalTo: ratingView.topAnchor, constant: 16),
            ratingGrid.centerXAnchor.constraint(equalTo: ratingView.centerXAnchor),
        ])

        let tabs = NSTabView()
        for (title, view) in [("Режимы", modesView), ("Показ", lookView), ("Оценка", ratingView)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }
        let showButton = NSButton(title: "Показать фразу", target: nil, action: nil)
        bind(showButton) { [unowned self] in self.app.showNext() }
        pin([tabs, showButton], in: window.contentView!)

        refresh()
        window.center()
    }

    /// Подтянуть текущее состояние: файлы фраз могли поправить снаружи.
    func refresh() {
        if app.modes.mode(selectedID) == nil { selectedID = BeingMode.defaultID }
        modeList.reloadData()
        selectRow()
        loadSelected()
    }

    private func selectRow() {
        if let i = app.modes.modes.firstIndex(where: { $0.id == selectedID }) {
            modeList.selectRowIndexes([i], byExtendingSelection: false)
            modeList.scrollRowToVisible(i)
        }
    }

    /// Показать выбранный режим в правой части.
    private func loadSelected() {
        let m = selected
        if nameField.stringValue != m.name { nameField.stringValue = m.name }
        let current = app.phrasesText(m.id)
        if text.string != current { text.string = current }
        removeButton.isEnabled = !m.isDefault
        startButton.isHidden = m.isDefault
        syncs.forEach { $0() }
    }

    private func addMode() {
        selectedID = app.addMode().id
        modeList.reloadData()
        selectRow()
        loadSelected()
        window.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    private func confirmRemove() {
        let m = selected
        guard !m.isDefault else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить режим «\(m.title)» и его фразы?"
        alert.informativeText = "Фразы режима удалятся вместе с ним, вернуть их не получится."
        alert.addButton(withTitle: "Удалить").hasDestructiveAction = true
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let i = self.app.modes.modes.firstIndex { $0.id == m.id } ?? 1
            self.app.removeMode(m.id)
            self.selectedID = self.app.modes.modes[max(0, i - 1)].id
            self.refresh()
        }
    }

    // MARK: Список режимов

    func numberOfRows(in tableView: NSTableView) -> Int { app.modes.modes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let m = app.modes.modes[row]
        let s = NSMutableAttributedString(string: m.title, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        if m.isDefault {
            s.append(NSAttributedString(string: " · по умолчанию",
                                        attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                     .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let label = NSTextField(labelWithAttributedString: s)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = modeList.selectedRow
        guard app.modes.modes.indices.contains(row) else { return }
        guard app.modes.modes[row].id != selectedID else { return }
        selectedID = app.modes.modes[row].id
        loadSelected()
    }

    /// Название сохраняется на каждую букву, как и фразы.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        app.updateMode(selectedID) { $0.name = nameField.stringValue }
        if let i = app.modes.modes.firstIndex(where: { $0.id == selectedID }) {
            modeList.reloadData(forRowIndexes: [i], columnIndexes: [0])
        }
    }

    func textDidChange(_ notification: Notification) { app.savePhrases(text.string, for: selectedID) }

    func windowWillClose(_ notification: Notification) {
        app.savePhrases(text.string, for: selectedID)
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
    }

    // MARK: Конструкторы контролов

    private func bind(_ control: NSControl, _ run: @escaping () -> Void) {
        let a = Action(run)
        actions.append(a)
        control.target = a
        control.action = #selector(Action.fire)
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func numberRow(_ range: ClosedRange<Int>, prefix: String? = nil, unit: String,
                           get: @escaping () -> Int, set: @escaping (Int) -> Void) -> NSView {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        let field = NSTextField()
        field.formatter = formatter
        field.alignment = .right
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        let apply: (Int) -> Void = { v in
            let m = v.clamped(range)
            field.integerValue = m
            stepper.integerValue = m
            set(m)
        }
        bind(field) { apply(field.integerValue) }
        bind(stepper) { apply(stepper.integerValue) }
        syncs.append { field.integerValue = get(); stepper.integerValue = get() }
        return row((prefix.map { [label($0)] } ?? []) + [field, stepper, label(unit)])
    }

    private func slider(_ range: ClosedRange<Double>,
                        get: @escaping () -> Double, set: @escaping (Double) -> Void) -> NSView {
        let s = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound,
                         target: nil, action: nil)
        s.isContinuous = true
        s.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        let show = { value.stringValue = "\(Int(s.doubleValue.rounded()))" }
        bind(s) { show(); set(s.doubleValue.rounded()) }
        syncs.append { s.doubleValue = get(); show() }
        return row([s, value])
    }

    private func popup(_ items: [String], get: @escaping () -> Int, set: @escaping (Int) -> Void) -> NSView {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        bind(p) { set(p.indexOfSelectedItem) }
        syncs.append { p.selectItem(at: get()) }
        return p
    }

    private func checkbox(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSView {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        bind(b) { set(b.state == .on) }
        syncs.append { b.state = get() ? .on : .off }
        return b
    }

    private func colorRow(clearTitle: String, placeholder: NSColor,
                          get: @escaping () -> NSColor?, set: @escaping (NSColor?) -> Void) -> NSView {
        let well = NSColorWell()
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let clear = NSButton(title: clearTitle, target: nil, action: nil)
        bind(well) { set(well.color) }
        bind(clear) {
            well.deactivate()
            set(nil)
            well.color = placeholder
        }
        syncs.append { well.color = get() ?? placeholder }
        return row([well, clear])
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 6
        return s
    }

    /// Раскладка: вкладки растягиваются, кнопка стоит под ними справа.
    private func pin(_ views: [NSView], in container: NSView) {
        let (top, bottom) = (views[0], views[1])
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            bottom.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var modeEnd: Timer?
    private let bubble = Bubble()
    private var settings: SettingsWindow?
    private var bag: [String] = []
    private var nextIndex = 0                      // следующая фраза режима «по списку»
    private var deckMode: String?                  // для какого режима собрана колода
    private var lastShown: String?
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var modeItem: NSMenuItem!
    private var menuActions: [Action] = []
    private(set) var look = Look.load()
    private(set) var rating = RatingSettings.load()
    private var ticks = 0
    private var stats: (window: NSWindow, model: StatsModel)?
    private var updater: SPUStandardUpdaterController!

    private lazy var dataDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nudge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private(set) lazy var modes = ModeStore(dir: dataDir)

    func applicationDidFinishLaunching(_ note: Notification) {
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // В строке меню свой значок: белый с чёрной чертой. Берём файл напрямую,
        // иначе система перекрасит его под стиль значков macOS.
        let icon = Bundle.main.image(forResource: "MenuIcon") ?? (NSApp.applicationIconImage.copy() as! NSImage)
        icon.size = NSSize(width: 22, height: 22)
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("График жизни")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Показать сейчас", action: #selector(showNow), keyEquivalent: "")
        menu.addItem(withTitle: "Оценить состояние", action: #selector(rateNow), keyEquivalent: "")
        menu.addItem(withTitle: "Статистика…", action: #selector(openStats), keyEquivalent: "")
        menu.addItem(.separator())
        modeItem = menu.addItem(withTitle: "Режим", action: nil, keyEquivalent: "")
        modeItem.submenu = NSMenu()
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        pauseItem = menu.addItem(withTitle: "Пауза", action: #selector(togglePause), keyEquivalent: "")
        loginItem = menu.addItem(withTitle: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "О приложении", action: #selector(openAbout), keyEquivalent: "")
        let checkItem = menu.addItem(withTitle: "Проверить обновления…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkItem.target = updater
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(withTitle: "Версия \(version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateLoginItem()

        bubble.onRate = { [weak self] in self?.recordRating($0, at: $1, comment: $2) }
        installMainMenu()
        startTimer()
        scheduleModeEnd()                              // режим, включённый до перезапуска, продолжается
        warnIfTranslocated()
    }

    // MARK: Обновления

    /// Обновление скачалось само в фоне. Ставим его сразу и перезапускаемся,
    /// но не посреди показа плашки, чтобы не оборвать ответ.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installWhenIdle(immediateInstallationBlock)
        return true
    }

    private func installWhenIdle(_ install: @escaping () -> Void) {
        guard bubble.isVisible else { install(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.installWhenIdle(install) }
    }

    /// У приложения без значка в доке Sparkle показывает напоминания об обновлениях деликатно.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Приложение, запущенное прямо из «Загрузок» или из открытого образа диска, обновиться не сможет:
    /// macOS держит его во временной копии или на диске только для чтения.
    private func warnIfTranslocated() {
        let path = Bundle.main.bundlePath
        guard path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Перенесите «График жизни» в «Программы»"
        alert.informativeText = "Сейчас приложение открыто не из папки «Программы», и macOS не даст ему обновляться. Закройте его, перетащите в «Программы» и откройте оттуда."
        alert.runModal()
    }

    /// Без главного меню в окне настроек не работают ⌘C, ⌘V, ⌘Z, ⌘A и ⌘W.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu()
        appItem.submenu!.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu!.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = main.addItem(withTitle: "Правка", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Таймер

    /// Запускает показы с интервалом текущего режима. Заодно снимает паузу.
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(modes.current.intervalMinutes * 60), repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        pauseItem.title = "Пауза"
    }

    private var isPaused: Bool { timer == nil }

    @objc private func togglePause() {
        if isPaused {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
            pauseItem.title = "Продолжить"
        }
    }

    // MARK: Режимы

    /// Включает режим на заданное число минут (nil — пока не выключат) и сразу показывает первую фразу.
    func startMode(_ id: String, minutes: Int?) {
        guard let mode = modes.mode(id), !mode.isDefault else { return }
        modes.setActive(ActiveMode(id: id, until: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }))
        scheduleModeEnd()
        startTimer()
        showNext()
    }

    @objc func stopMode() {
        modes.setActive(nil)
        modeChanged()
    }

    /// Режим сменился сам или его выключили: таймер берёт интервал нового режима.
    private func modeChanged() {
        scheduleModeEnd()
        if !isPaused { startTimer() }
    }

    private func scheduleModeEnd() {
        modeEnd?.invalidate()
        modeEnd = nil
        guard let until = modes.active?.until else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.modes.dropExpired() else { return }
            self.modeChanged()
        }
        RunLoop.main.add(t, forMode: .common)
        modeEnd = t
    }

    func updateMode(_ id: String, _ change: (inout BeingMode) -> Void) {
        let before = modes.mode(id)?.intervalMinutes
        modes.update(id, change)
        if id == modes.current.id, before != modes.current.intervalMinutes, !isPaused { startTimer() }
    }

    func addMode() -> BeingMode { modes.add() }

    func removeMode(_ id: String) {
        let wasActive = modes.active?.id == id
        modes.remove(id)
        if wasActive { modeChanged() }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Подменю «Режим» собирается заново при каждом открытии: в нём время до конца режима.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu, let sub = modeItem.submenu else { return }
        if modes.dropExpired() { modeChanged() }
        sub.removeAllItems()
        menuActions = []
        func add(_ title: String, to m: NSMenu, _ run: (() -> Void)?) -> NSMenuItem {
            let item = m.addItem(withTitle: title, action: nil, keyEquivalent: "")
            if let run {
                let a = Action(run)
                menuActions.append(a)
                item.target = a
                item.action = #selector(Action.fire)
            }
            return item
        }

        if let a = modes.active, let m = modes.mode(a.id) {
            modeItem.title = "Режим: " + m.title + (a.until.map { " · до " + AppDelegate.clock.string(from: $0) } ?? "")
            _ = add("Выключить режим", to: sub) { [weak self] in self?.stopMode() }
            sub.addItem(.separator())
        } else {
            modeItem.title = "Режим"
        }
        let others = modes.modes.filter { !$0.isDefault }
        if others.isEmpty {
            _ = add("Режимов пока нет", to: sub, nil)
        }
        for m in others {
            let item = add(m.title, to: sub, nil)
            item.state = modes.active?.id == m.id ? .on : .off
            let durations = NSMenu()
            for d in modeDurations {
                _ = add(d.title, to: durations) { [weak self] in self?.startMode(m.id, minutes: d.minutes) }
            }
            item.submenu = durations
        }
        sub.addItem(.separator())
        _ = add("Настроить режимы…", to: sub) { [weak self] in self?.openSettings() }
    }

    // MARK: Фразы

    func phrasesText(_ id: String) -> String { modes.phrasesText(id) }

    func savePhrases(_ text: String, for id: String) {
        do {
            try modes.savePhrases(text, id)
        } catch {
            NSSound.beep()
            NSLog("График жизни: не удалось сохранить фразы: \(error)")
        }
    }

    /// Фраза текущего режима: по списку по кругу или из перемешанной колоды,
    /// где каждая фраза выпадает один раз за круг.
    private func nextPhrase() -> String? {
        let mode = modes.current
        let all = modes.phrases(mode.id)
        if deckMode != mode.id {
            deckMode = mode.id
            bag = []
            nextIndex = 0
        }
        if mode.ordered {
            guard !all.isEmpty else { return nil }
            if nextIndex >= all.count { nextIndex = 0 }
            lastShown = all[nextIndex]
            nextIndex += 1
            return lastShown
        }
        bag.removeAll { !all.contains($0) }        // учесть удалённые строки
        if bag.isEmpty {
            bag = all.shuffled()
            if bag.count > 1, bag.last == lastShown { bag.swapAt(0, bag.count - 1) }
        }
        lastShown = bag.popLast()
        return lastShown
    }

    // MARK: Показ

    /// Срабатывание таймера: обычно фраза, каждый N-й раз — оценка состояния, если режим её просит.
    private func tick() {
        if modes.dropExpired() { modeChanged() }
        ticks += 1
        if modes.current.askRating, ticks % rating.every == 0 {
            showRating()
        } else {
            showNext()
        }
    }

    @objc private func showNow() { showNext() }
    @objc private func rateNow() { showRating() }

    func showNext() {
        guard let phrase = nextPhrase() else { return }
        bubble.show(.phrase(phrase), look: look, seconds: modes.current.seconds, animated: true)
    }

    func showRating() {
        let prompt = rating.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        bubble.show(.rating(prompt.isEmpty ? RatingSettings.defaultPrompt : prompt), look: look,
                    seconds: modes.current.seconds, animated: true)
    }

    func updateRating(_ change: (inout RatingSettings) -> Void) {
        change(&rating)
        rating.save()
    }

    // MARK: Журнал оценок

    private lazy var ratingsURL = dataDir.appendingPathComponent("ratings.csv")

    private static let logHeader = "Дата,Оценка из 10,Комментарий,Режим"

    private func ensureRatingsLog() throws {
        guard FileManager.default.fileExists(atPath: ratingsURL.path) else {
            try (AppDelegate.logHeader + "\n").write(to: ratingsURL, atomically: true, encoding: .utf8)
            return
        }
        // Журналы из прошлых версий: дописать в заголовок новые столбцы. Строки не трогаем,
        // у старых оценок режима нет, они считаются оценками обычного режима.
        let text = try String(contentsOf: ratingsURL, encoding: .utf8)
        let header = text.prefix { !$0.isNewline }
        if header.hasPrefix("Дата,"), header != AppDelegate.logHeader {
            try (AppDelegate.logHeader + text.dropFirst(header.count))
                .write(to: ratingsURL, atomically: true, encoding: .utf8)
        }
    }

    /// Поле CSV в кавычках, в одну строку.
    private static func csvField(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func recordRating(_ points: Int, at date: Date, comment: String?) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "\(f.string(from: date)),\(points),\(comment.map(AppDelegate.csvField) ?? ""),"
            + AppDelegate.csvField(modes.current.title) + "\n"
        do {
            try ensureRatingsLog()
            let h = try FileHandle(forWritingTo: ratingsURL)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
            stats?.model.reload()
        } catch {
            NSSound.beep()
            NSLog("График жизни: не удалось записать оценку: \(error)")
        }
    }

    @objc func openStats() {
        if stats == nil {
            let model = StatsModel(url: ratingsURL) { [weak self] in self?.modes.modes[0].title ?? "Обычный" }
            let view = StatsView(model: model, onOpenCSV: { [weak self] in self?.openRatingsLog() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Статистика"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            stats = (w, model)
        }
        stats!.model.reload()
        NSApp.activate(ignoringOtherApps: true)
        stats!.window.makeKeyAndOrderFront(nil)
    }

    func openRatingsLog() {
        try? ensureRatingsLog()
        NSWorkspace.shared.open(ratingsURL)
    }

    /// Меняет оформление, сохраняет и сразу показывает, как это выглядит.
    func updateLook(_ change: (inout Look) -> Void) {
        change(&look)
        look.save()
        guard !bubble.restyle(look) else { return }
        let sample = lastShown ?? modes.phrases(modes.current.id).first ?? "Так будет выглядеть фраза"
        bubble.show(.phrase(sample), look: look, seconds: modes.current.seconds, animated: false)
    }

    /// Короткая сводка: что это за приложение и зачем оно.
    @objc private func openAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "График жизни"
        alert.informativeText = """
        Помогает замечать, как на самом деле проходит день.

        Раз в несколько минут поверх всех окон появляется фраза или вопрос из вашего списка, чтобы вернуть внимание к важному.

        Режимы бытия — свои наборы фраз для особых отрезков времени: занятия, продажи, встречи. Включаются из меню на нужное время, потом приложение само возвращается к обычным фразам.

        Иногда приложение просит оценить состояние звёздами от 1 до 10 и коротко написать почему. Из оценок складывается график: видно, когда вам хорошо, когда плохо и что на это влияет.

        Всё хранится только на этом Mac. Обновления приходят сами.

        Версия \(version)
        """
        if let icon = Bundle.main.image(forResource: "AppIcon") { alert.icon = icon }
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings!.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settings!.window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bubble.flush()                                 // оценка, ждавшая комментария, не пропадёт
    }

    // MARK: Автозапуск

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        updateLoginItem()
    }

    private func updateLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // без иконки в доке
app.run()
