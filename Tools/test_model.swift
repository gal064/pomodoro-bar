import Foundation

var failed = 0
func check(_ cond: Bool, _ msg: String) {
    print((cond ? "PASS  " : "FAIL  ") + msg)
    if !cond { failed += 1 }
}

let m = TimerModel()

if CommandLine.arguments.contains("--complete") {
    // Full end-to-end: complete a focus session (1 min) and verify the
    // session log, mode switch, and CSV output.
    let before = m.sessions.count
    m.task = "verify run"
    m.setDuration(.focus, 1)
    var completed: TimerModel.Mode?
    m.onComplete = { completed = $0 }
    m.start()
    let deadline = Date().addingTimeInterval(80)
    while m.sessions.count == before && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    check(completed == .focus, "onComplete fired for focus")
    check(m.sessions.count == before + 1, "a session was logged")
    check(m.sessions.first?.task == "verify run", "logged task text matches")
    check(m.sessions.first?.minutes == 1, "logged minutes == 1")
    check(m.mode == .rest, "auto-switched to Break after focus")
    let csv = m.exportCSV()
    check(csv.hasPrefix("task,minutes,completed_at"), "CSV has header")
    check(csv.contains("verify run,1,"), "CSV contains the session row")
    print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

// ---- fast logic checks ----
m.setDuration(.focus, 200); check(m.focusMin == 90, "focus clamps to 90")
m.setDuration(.focus, 0);   check(m.focusMin == 1,  "focus clamps to 1")
m.setDuration(.focus, 25);  check(m.focusMin == 25, "focus set to 25")
m.setDuration(.rest, 5);    check(m.breakMin == 5,  "break set to 5")

check(m.timeString == "25:00", "initial time is 25:00 (got \(m.timeString))")
check(m.statusText == "ready", "initial status is ready")
check(abs(m.fraction) < 0.001, "initial fraction is 0")

m.selectMode(.rest)
check(m.mode == .rest && m.timeString == "05:00", "switch to Break shows 05:00")
m.selectMode(.focus)

m.start()
check(m.running, "running after start")
check(m.statusText == "running", "status is running")
RunLoop.main.run(until: Date().addingTimeInterval(2.2))
check(m.remaining < 25 * 60 && m.remaining > 25 * 60 - 5, "countdown decremented (\(m.timeString))")
check(m.fraction > 0, "fraction advanced (\(m.fraction))")
m.pause()
check(!m.running && m.statusText == "paused", "pause stops and reports paused")
m.reset()
check(m.timeString == "25:00" && m.statusText == "ready", "reset returns to 25:00 / ready")

check(m.exportCSV() == "task,minutes,completed_at", "empty log CSV is header only")

print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
