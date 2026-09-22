import Foundation

/// A completed focus session, persisted to disk.
struct Session: Codable {
    var task: String
    var minutes: Int
    var at: Date
}

/// The single source of truth for the timer. Mirrors the behavior of the
/// original pomodoro.html: focus/break modes, 1-90 minute durations,
/// auto-start-break, a capped session log, and drift-free countdown.
final class TimerModel {

    enum Mode: String {
        case focus
        case rest   // "break" in the UI

        var display: String { self == .focus ? "Focus" : "Break" }
    }

    // MARK: Persistence keys
    private enum Key {
        static let focus = "PomodoroBar.focusMin"
        static let brk = "PomodoroBar.breakMin"
        static let autoBreak = "PomodoroBar.autoBreak"
        static let task = "PomodoroBar.task"
        static let sessions = "PomodoroBar.sessions"
        static let decisions = "PomodoroBar.decisions"
        static let ackDate = "PomodoroBar.decisionsAckDate"
    }

    private let defaults = UserDefaults.standard

    // MARK: Persisted settings
    private(set) var focusMin: Int
    private(set) var breakMin: Int
    var autoStartBreak: Bool {
        didSet { defaults.set(autoStartBreak, forKey: Key.autoBreak) }
    }
    var task: String {
        didSet { defaults.set(task, forKey: Key.task) }
    }
    private(set) var sessions: [Session]

    /// Free-text personal decisions that must be acknowledged once per day.
    var decisionsText: String {
        didSet { defaults.set(decisionsText, forKey: Key.decisions) }
    }
    /// The local calendar day ("yyyy-MM-dd") the decisions were last acknowledged.
    private(set) var lastAckDate: String

    // MARK: Runtime state
    private(set) var mode: Mode = .focus
    private(set) var remaining: TimeInterval
    private(set) var running = false
    private var endTime = Date()
    private var timer: Timer?

    /// Fired on every state change (tick, start, pause, mode switch...).
    var onChange: (() -> Void)?
    /// Fired when a countdown reaches zero; argument is the mode that finished.
    var onComplete: ((Mode) -> Void)?

    init() {
        let f = defaults.object(forKey: Key.focus) as? Int ?? 25
        let b = defaults.object(forKey: Key.brk) as? Int ?? 5
        focusMin = min(90, max(1, f))
        breakMin = min(90, max(1, b))
        autoStartBreak = defaults.bool(forKey: Key.autoBreak)
        task = defaults.string(forKey: Key.task) ?? ""
        if let data = defaults.data(forKey: Key.sessions),
           let decoded = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = decoded
        } else {
            sessions = []
        }
        decisionsText = defaults.string(forKey: Key.decisions) ?? ""
        lastAckDate = defaults.string(forKey: Key.ackDate) ?? ""
        remaining = Double(focusMin) * 60
    }

    // MARK: Derived values

    func duration(_ m: Mode) -> Int { m == .focus ? focusMin : breakMin }

    /// Elapsed fraction of the current mode (0...1) for the progress ring.
    var fraction: Double {
        let total = Double(duration(mode)) * 60
        return total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
    }

    var timeString: String {
        let sec = max(0, Int(remaining.rounded()))
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    /// "ready" (fresh), "paused" (mid-countdown, stopped), or "running".
    var statusText: String {
        if running { return "running" }
        return remaining < Double(duration(mode)) * 60 ? "paused" : "ready"
    }

    // MARK: Decisions

    /// Today's local calendar day, formatted "yyyy-MM-dd".
    var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var hasDecisions: Bool {
        !decisionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var acknowledgedToday: Bool { lastAckDate == todayString }

    /// True when there are decisions written but not yet acknowledged today.
    var needsAcknowledgement: Bool { hasDecisions && !acknowledgedToday }

    func acknowledgeDecisions() {
        lastAckDate = todayString
        defaults.set(lastAckDate, forKey: Key.ackDate)
        onChange?()
    }

    // MARK: Transport

    func start() {
        guard !running, remaining > 0 else { return }
        running = true
        endTime = Date().addingTimeInterval(remaining)
        startTicker()
        onChange?()
    }

    func pause() {
        guard running else { return }
        running = false
        remaining = max(0, endTime.timeIntervalSinceNow)
        stopTicker()
        onChange?()
    }

    func reset() {
        running = false
        stopTicker()
        remaining = Double(duration(mode)) * 60
        onChange?()
    }

    func toggle() { running ? pause() : start() }

    /// Switch tabs. Keeps a paused/running countdown intact if already on `m`.
    func selectMode(_ m: Mode) {
        guard m != mode else { return }
        running = false
        stopTicker()
        applyMode(m)
        onChange?()
    }

    private func applyMode(_ m: Mode) {
        mode = m
        remaining = Double(duration(m)) * 60
    }

    // MARK: Ticking

    private func startTicker() {
        stopTicker()
        // Fire in .common mode so the countdown keeps updating while the
        // popover or a menu is tracking. 0.25s keeps the display smooth.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        remaining = endTime.timeIntervalSinceNow
        if remaining <= 0 {
            remaining = 0
            complete()
        }
        onChange?()
    }

    private func complete() {
        running = false
        stopTicker()
        let finished = mode
        if finished == .focus {
            let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            logSession(task: trimmed.isEmpty ? "Untitled focus" : trimmed, minutes: focusMin)
            applyMode(.rest)            // auto-switch to Break
            onComplete?(finished)       // chime + notification
            if autoStartBreak { start() }
        } else {
            applyMode(.focus)           // cycle back to Focus
            onComplete?(finished)
        }
    }

    // MARK: Durations

    func setDuration(_ m: Mode, _ value: Int) {
        let v = min(90, max(1, value))
        if m == .focus {
            focusMin = v
            defaults.set(v, forKey: Key.focus)
        } else {
            breakMin = v
            defaults.set(v, forKey: Key.brk)
        }
        if !running && mode == m { reset() } else { onChange?() }
    }

    // MARK: Sessions

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: Key.sessions)
        }
    }

    private func logSession(task: String, minutes: Int) {
        sessions.insert(Session(task: task, minutes: minutes, at: Date()), at: 0)
        if sessions.count > 500 { sessions.removeLast(sessions.count - 500) }
        saveSessions()
    }

    func clearSessions() {
        sessions = []
        saveSessions()
        onChange?()
    }

    /// CSV with the same columns/quoting as the web export.
    func exportCSV() -> String {
        var rows: [[String]] = [["task", "minutes", "completed_at"]]
        let iso = ISO8601DateFormatter()
        for s in sessions.reversed() {
            rows.append([s.task, String(s.minutes), iso.string(from: s.at)])
        }
        return rows.map { row in
            row.map { cell -> String in
                if cell.contains("\"") || cell.contains(",") || cell.contains("\n") {
                    return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return cell
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}
