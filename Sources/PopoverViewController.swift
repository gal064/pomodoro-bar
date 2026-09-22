import Cocoa

/// The native UI shown inside the menu bar popover. Programmatic AppKit,
/// laid out top-to-bottom to echo the original web design. Hosts two views —
/// the Timer and the daily Decisions — switched with a top-level control.
final class PopoverViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {

    private let model: TimerModel
    /// Called with the gear button so the app can pop up its menu next to it.
    var onGear: ((NSButton) -> Void)?

    private let focusColor = NSColor(hex: 0xdf8a2b)
    private let breakColor = NSColor(hex: 0x2ea287)
    private let dangerColor = NSColor(hex: 0xc14a3b)
    private let muted = NSColor(hex: 0x797b85)
    private let width: CGFloat = 300

    // Top-level navigation
    private let viewTabs = NSSegmentedControl(labels: ["Timer", "Decisions"],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let banner = NSButton(title: "", target: nil, action: nil)
    private let timerContainer = NSStackView()
    private let decisionsContainer = NSStackView()
    private var currentView = 0

    // Timer controls
    private let dot = NSView()
    private let tabs = NSSegmentedControl(labels: ["Focus", "Break"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let ring = RingView()
    private let timeLabel = NSTextField(labelWithString: "25:00")
    private let phaseLabel = NSTextField(labelWithString: "FOCUS")
    private let startBtn = NSButton(title: "Start", target: nil, action: nil)
    private let pauseBtn = NSButton(title: "Pause", target: nil, action: nil)
    private let resetBtn = NSButton(title: "Reset", target: nil, action: nil)
    private let taskField = NSTextField(string: "")
    private let focusVal = NSTextField(labelWithString: "25")
    private let breakVal = NSTextField(labelWithString: "5")
    private let autoSwitch = NSSwitch()
    private let exportBtn = NSButton(title: "Export CSV", target: nil, action: nil)
    private let clearBtn = NSButton(title: "Clear", target: nil, action: nil)
    private let logStack = NSStackView()
    private let gear = NSButton(title: "\u{2699}\u{fe0e}", target: nil, action: nil)

    // Decisions controls
    private let decisionsTextView = NSTextView()
    private let ackButton = NSButton(title: "Acknowledge for today", target: nil, action: nil)
    private let ackStatus = NSTextField(labelWithString: "")

    private var clearArmed = false
    private var clearTimer: Timer?

    init(model: TimerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private var accent: NSColor { model.mode == .focus ? focusColor : breakColor }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 560))
        root.widthAnchor.constraint(equalToConstant: width).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        func fill(_ v: NSView, _ parent: NSStackView, minus: CGFloat) {
            v.widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -minus).isActive = true
        }

        // ---- header ----
        let wordmark = NSTextField(labelWithString: "pomodoro")
        wordmark.font = .systemFont(ofSize: 14, weight: .semibold)
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        dot.layer?.cornerRadius = 4.5
        gear.target = self
        gear.action = #selector(gearClicked)
        gear.isBordered = false
        gear.font = .systemFont(ofSize: 15)
        gear.contentTintColor = muted
        let header = NSStackView(views: [dot, wordmark, NSView(), gear])
        header.spacing = 8
        header.alignment = .centerY
        header.orientation = .horizontal
        stack.addArrangedSubview(header)
        fill(header, stack, minus: 32)

        // ---- acknowledgement banner (hidden unless a decision is due) ----
        banner.isBordered = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(hex: 0xd6353a).cgColor
        banner.layer?.cornerRadius = 10
        banner.target = self
        banner.action = #selector(bannerClicked)
        banner.attributedTitle = NSAttributedString(
            string: "Please acknowledge today's decisions",
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold),
                         .foregroundColor: NSColor.white])
        banner.heightAnchor.constraint(equalToConstant: 42).isActive = true
        banner.isHidden = true
        stack.addArrangedSubview(banner)
        fill(banner, stack, minus: 32)

        // ---- top-level tabs ----
        viewTabs.target = self
        viewTabs.action = #selector(viewTabChanged)
        viewTabs.selectedSegment = 0
        stack.addArrangedSubview(viewTabs)
        fill(viewTabs, stack, minus: 32)

        // ---- timer view ----
        buildTimerView(into: timerContainer, fill: { fill($0, self.timerContainer, minus: 0) })
        stack.addArrangedSubview(timerContainer)
        fill(timerContainer, stack, minus: 32)

        // ---- decisions view ----
        buildDecisionsView(into: decisionsContainer, fill: { fill($0, self.decisionsContainer, minus: 0) })
        decisionsContainer.isHidden = true
        stack.addArrangedSubview(decisionsContainer)
        fill(decisionsContainer, stack, minus: 32)

        self.view = root
        refresh()
    }

    // MARK: Timer view construction

    private func buildTimerView(into c: NSStackView, fill: (NSView) -> Void) {
        c.orientation = .vertical
        c.alignment = .centerX
        c.spacing = 14

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        c.addArrangedSubview(tabs)
        fill(tabs)

        let stage = NSView()
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.widthAnchor.constraint(equalToConstant: 190).isActive = true
        stage.heightAnchor.constraint(equalToConstant: 190).isActive = true
        ring.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(ring)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 46, weight: .medium)
        timeLabel.alignment = .center
        phaseLabel.font = .systemFont(ofSize: 11, weight: .medium)
        phaseLabel.textColor = muted
        phaseLabel.alignment = .center
        let readout = NSStackView(views: [timeLabel, phaseLabel])
        readout.orientation = .vertical
        readout.spacing = 4
        readout.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(readout)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: stage.topAnchor),
            ring.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            readout.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            readout.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])
        c.addArrangedSubview(stage)

        startBtn.target = self; startBtn.action = #selector(startClicked)
        pauseBtn.target = self; pauseBtn.action = #selector(pauseClicked)
        resetBtn.target = self; resetBtn.action = #selector(resetClicked)
        for b in [startBtn, pauseBtn, resetBtn] { b.bezelStyle = .rounded }
        startBtn.keyEquivalent = "\r"
        let controls = NSStackView(views: [startBtn, pauseBtn, resetBtn])
        controls.orientation = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 8
        c.addArrangedSubview(controls)
        fill(controls)

        let taskLabel = NSTextField(labelWithString: "WORKING ON")
        taskLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        taskLabel.textColor = muted
        taskField.placeholderString = "Write investor update"
        taskField.delegate = self
        taskField.font = .systemFont(ofSize: 13)
        let taskCol = NSStackView(views: [taskLabel, taskField])
        taskCol.orientation = .vertical
        taskCol.alignment = .leading
        taskCol.spacing = 6
        taskField.widthAnchor.constraint(equalTo: taskCol.widthAnchor).isActive = true
        c.addArrangedSubview(taskCol)
        fill(taskCol)

        let focusRow = durationRow(name: "Focus", valueLabel: focusVal, mode: .focus)
        let breakRow = durationRow(name: "Break", valueLabel: breakVal, mode: .rest)
        let durs = NSStackView(views: [focusRow, breakRow])
        durs.orientation = .horizontal
        durs.distribution = .fillEqually
        durs.spacing = 12
        c.addArrangedSubview(durs)
        fill(durs)

        let autoLabel = NSTextField(labelWithString: "Auto-start break")
        autoLabel.font = .systemFont(ofSize: 13)
        autoSwitch.target = self
        autoSwitch.action = #selector(autoToggled)
        let autoRow = NSStackView(views: [autoLabel, NSView(), autoSwitch])
        autoRow.orientation = .horizontal
        autoRow.alignment = .centerY
        c.addArrangedSubview(autoRow)
        fill(autoRow)

        let logTitle = NSTextField(labelWithString: "Completed sessions")
        logTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        exportBtn.isBordered = false
        exportBtn.target = self; exportBtn.action = #selector(exportClicked)
        clearBtn.isBordered = false
        clearBtn.target = self; clearBtn.action = #selector(clearClicked)
        clearBtn.contentTintColor = dangerColor
        for b in [exportBtn, clearBtn] { b.font = .systemFont(ofSize: 11) }
        let logHeader = NSStackView(views: [logTitle, NSView(), exportBtn, clearBtn])
        logHeader.orientation = .horizontal
        logHeader.alignment = .centerY
        logHeader.spacing = 10
        c.addArrangedSubview(logHeader)
        fill(logHeader)

        logStack.orientation = .vertical
        logStack.alignment = .leading
        logStack.spacing = 0
        c.addArrangedSubview(logStack)
        fill(logStack)
    }

    // MARK: Decisions view construction

    private func buildDecisionsView(into c: NSStackView, fill: (NSView) -> Void) {
        c.orientation = .vertical
        c.alignment = .leading
        c.spacing = 10

        let title = NSTextField(labelWithString: "Decisions")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        c.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Write what you want to keep front of mind, then acknowledge it once each day.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = muted
        c.addArrangedSubview(subtitle)
        fill(subtitle)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        decisionsTextView.isRichText = false
        decisionsTextView.font = .systemFont(ofSize: 13)
        decisionsTextView.isVerticallyResizable = true
        decisionsTextView.isHorizontallyResizable = false
        decisionsTextView.autoresizingMask = [.width]
        decisionsTextView.minSize = NSSize(width: 0, height: 0)
        decisionsTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                           height: CGFloat.greatestFiniteMagnitude)
        decisionsTextView.textContainerInset = NSSize(width: 4, height: 6)
        decisionsTextView.textContainer?.widthTracksTextView = true
        decisionsTextView.delegate = self
        decisionsTextView.string = model.decisionsText
        scroll.documentView = decisionsTextView
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        c.addArrangedSubview(scroll)
        fill(scroll)

        ackButton.bezelStyle = .rounded
        ackButton.target = self
        ackButton.action = #selector(acknowledgeClicked)
        c.addArrangedSubview(ackButton)
        fill(ackButton)

        ackStatus.font = .systemFont(ofSize: 12)
        c.addArrangedSubview(ackStatus)
        fill(ackStatus)
    }

    private func durationRow(name: String, valueLabel: NSTextField, mode: TimerModel.Mode) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = muted
        let minus = stepButton("\u{2212}")
        let plus = stepButton("+")
        minus.tag = mode == .focus ? -1 : -2
        plus.tag = mode == .focus ? 1 : 2
        minus.target = self; minus.action = #selector(stepClicked(_:))
        plus.target = self; plus.action = #selector(stepClicked(_:))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        valueLabel.alignment = .center
        valueLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let stepper = NSStackView(views: [minus, valueLabel, plus])
        stepper.orientation = .horizontal
        stepper.spacing = 6
        stepper.alignment = .centerY
        let row = NSStackView(views: [nameLabel, NSView(), stepper])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.wantsLayer = true
        row.layer?.borderWidth = 1
        row.layer?.borderColor = NSColor(white: 0, alpha: 0.10).cgColor
        row.layer?.cornerRadius = 10
        return row
    }

    private func stepButton(_ title: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .circular
        b.font = .systemFont(ofSize: 13)
        return b
    }

    // MARK: View switching

    /// Reset to the Timer view and refresh; called each time the popover opens.
    func prepareForShow() {
        decisionsTextView.string = model.decisionsText
        selectView(0)
        refresh()
    }

    private func selectView(_ index: Int) {
        currentView = index
        viewTabs.selectedSegment = index
        timerContainer.isHidden = index != 0
        decisionsContainer.isHidden = index != 1
        updateAckState()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: width, height: view.fittingSize.height)
    }

    // MARK: Actions

    @objc private func gearClicked() { onGear?(gear) }
    @objc private func viewTabChanged() { selectView(viewTabs.selectedSegment) }
    @objc private func bannerClicked() { selectView(1) }

    @objc private func tabChanged() {
        model.selectMode(tabs.selectedSegment == 0 ? .focus : .rest)
    }
    @objc private func startClicked() { model.start() }
    @objc private func pauseClicked() { model.pause() }
    @objc private func resetClicked() { model.reset() }
    @objc private func autoToggled() { model.autoStartBreak = (autoSwitch.state == .on) }

    @objc private func acknowledgeClicked() {
        model.acknowledgeDecisions()   // fires onChange -> refresh via AppDelegate
        updateAckState()
    }

    @objc private func stepClicked(_ sender: NSButton) {
        let mode: TimerModel.Mode = abs(sender.tag) == 1 ? .focus : .rest
        let step = sender.tag > 0 ? 1 : -1
        model.setDuration(mode, model.duration(mode) + step)
    }

    @objc private func exportClicked() {
        guard !model.sessions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pomodoro-log.csv"
        panel.allowedContentTypes = []
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self = self else { return }
            try? self.model.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func clearClicked() {
        guard !model.sessions.isEmpty else { return }
        if !clearArmed {
            clearArmed = true
            clearBtn.title = "Confirm?"
            clearTimer?.invalidate()
            clearTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                self?.disarmClear()
            }
            return
        }
        disarmClear()
        model.clearSessions()
    }

    private func disarmClear() {
        clearArmed = false
        clearTimer?.invalidate()
        clearBtn.title = "Clear"
    }

    // Task field edits.
    func controlTextDidChange(_ obj: Notification) {
        model.task = taskField.stringValue
    }

    // Decisions text edits.
    func textDidChange(_ notification: Notification) {
        model.decisionsText = decisionsTextView.string
        updateAckState()
    }

    // MARK: Refresh

    func refresh() {
        dot.layer?.backgroundColor = accent.cgColor
        tabs.selectedSegment = model.mode == .focus ? 0 : 1
        ring.accent = accent
        ring.fraction = model.fraction
        timeLabel.textColor = .labelColor
        timeLabel.stringValue = model.timeString
        phaseLabel.stringValue = model.mode.display.uppercased()
        startBtn.isEnabled = !model.running
        pauseBtn.isEnabled = model.running
        exportBtn.contentTintColor = accent

        if !taskField.isEditing { taskField.stringValue = model.task }
        focusVal.stringValue = String(model.focusMin)
        breakVal.stringValue = String(model.breakMin)
        autoSwitch.state = model.autoStartBreak ? .on : .off

        let empty = model.sessions.isEmpty
        exportBtn.isEnabled = !empty
        clearBtn.isEnabled = !empty
        if empty && !clearArmed { clearBtn.title = "Clear" }
        rebuildLog(empty: empty)
        updateAckState()
    }

    private func updateAckState() {
        banner.isHidden = !(model.needsAcknowledgement && currentView == 0)
        ackButton.isEnabled = model.needsAcknowledgement
        ackButton.title = model.acknowledgedToday ? "Acknowledged for today \u{2713}" : "Acknowledge for today"

        if !model.hasDecisions {
            ackStatus.stringValue = "Write a decision above to start the daily check-in."
            ackStatus.textColor = muted
        } else if model.acknowledgedToday {
            ackStatus.stringValue = "Acknowledged for today."
            ackStatus.textColor = breakColor
        } else {
            ackStatus.stringValue = "Not acknowledged today."
            ackStatus.textColor = dangerColor
        }
    }

    private func rebuildLog(empty: Bool) {
        logStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if empty {
            let e = NSTextField(wrappingLabelWithString: "No sessions yet. Finish a focus timer and it lands here.")
            e.font = .systemFont(ofSize: 12)
            e.textColor = muted
            logStack.addArrangedSubview(e)
            e.widthAnchor.constraint(equalTo: logStack.widthAnchor).isActive = true
            return
        }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        for s in model.sessions.prefix(12) {
            let task = NSTextField(labelWithString: s.task)
            task.font = .systemFont(ofSize: 13)
            task.lineBreakMode = .byTruncatingTail
            task.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let meta = NSTextField(labelWithString: "\(s.minutes)m \u{00b7} \(df.string(from: s.at))")
            meta.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            meta.textColor = muted
            let row = NSStackView(views: [task, NSView(), meta])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            logStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: logStack.widthAnchor).isActive = true
        }
    }
}

// MARK: - helpers

extension NSTextField {
    var isEditing: Bool { currentEditor() != nil }
}
