import Cocoa
import UserNotifications
import ServiceManagement
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private let model = TimerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var vc: PopoverViewController!
    private let chime = Chime()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only agent; no dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Status item shows the live countdown.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Popover with the native UI.
        vc = PopoverViewController(model: model)
        vc.onGear = { [weak self] anchor in self?.showMenu(near: anchor) }
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = true

        // Wire the model to the UI + menu bar.
        model.onChange = { [weak self] in self?.updateStatusTitle(); self?.refreshPopover() }
        model.onComplete = { [weak self] finished in self?.handleComplete(finished) }

        // Notifications.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        ensureLoginItem()
        updateStatusTitle()
    }

    // MARK: Status title

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let icon = model.mode == .focus ? "\u{1F345}" : "\u{2615}"   // tomato / cup
        let text = model.statusText == "ready" ? "\(icon) ready" : "\(icon) \(model.timeString)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
    }

    private func refreshPopover() {
        if popover.isShown { vc.refresh() }
    }

    // MARK: Click handling

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu(near: statusItem.button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            vc.prepareForShow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startKeyMonitor()
        }
    }

    // MARK: Menu (right-click / gear)

    private func showMenu(near anchor: NSView?) {
        let menu = NSMenu()

        let loginItem = NSMenuItem(title: "Open at Login",
                                   action: #selector(toggleLoginItem),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit PomodoroBar",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        if let anchor = anchor {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: anchor.bounds.height + 4),
                       in: anchor)
        }
    }

    private let loginOptOutKey = "PomodoroBar.loginOptOut"

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(true, forKey: loginOptOutKey)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(false, forKey: loginOptOutKey)
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }

    /// Keep the app registered as a login item unless the user opted out.
    /// register() is idempotent, so this is safe to call on every launch.
    private func ensureLoginItem() {
        guard !UserDefaults.standard.bool(forKey: loginOptOutKey) else { return }
        try? SMAppService.mainApp.register()
    }

    // MARK: Completion

    private func handleComplete(_ finished: TimerModel.Mode) {
        chime.play()
        let title: String
        let body: String
        if finished == .focus {
            let t = model.task.trimmingCharacters(in: .whitespacesAndNewlines)
            title = "Focus session complete"
            body = (t.isEmpty ? "Nice work." : t) + " \u{00b7} Time for a break."
        } else {
            title = "Break's over"
            body = "Ready for the next focus session?"
        }
        notify(title: title, body: body)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Keyboard shortcuts (only while the popover is open)

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            // Ignore when typing in the task field.
            if let responder = event.window?.firstResponder,
               responder is NSText || responder is NSTextField {
                return event
            }
            if event.keyCode == 49 {            // space
                self.model.toggle()
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "r" {
                self.model.reset()
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopKeyMonitor()
    }
}

// MARK: - Two-tone completion chime (WebAudio equivalent, no external file)

final class Chime {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffer = Chime.makeBuffer(format: format)
    }

    func play() {
        guard let buffer = buffer else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    /// 880 Hz then 1174.66 Hz, 0.16s apart, each with a soft attack and
    /// exponential decay — the same shape as the page's WebAudio chime.
    private static func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let tones: [(freq: Double, start: Double)] = [(880, 0), (1174.66, 0.16)]
        let toneDur = 0.65
        let total = 0.16 + toneDur + 0.05
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buf.floatChannelData else { return nil }
        buf.frameLength = frames
        let amp = 0.22, attack = 0.02, k = 12.0
        for n in 0..<Int(frames) {
            let t = Double(n) / sr
            var sample = 0.0
            for tone in tones {
                let local = t - tone.start
                guard local >= 0, local <= toneDur else { continue }
                let env: Double = local < attack
                    ? amp * (local / attack)
                    : amp * exp(-(local - attack) * k)
                sample += env * sin(2 * Double.pi * tone.freq * local)
            }
            data[0][n] = Float(max(-1, min(1, sample)))
        }
        return buf
    }
}
