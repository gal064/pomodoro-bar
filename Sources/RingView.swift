import Cocoa

/// A circular progress ring drawn with CAShapeLayers. The progress stroke
/// starts at the top (12 o'clock) and grows clockwise, echoing the web ring.
final class RingView: NSView {

    private let track = CAShapeLayer()
    private let prog = CAShapeLayer()
    private let lineWidth: CGFloat = 10
    private let inset: CGFloat = 8

    var accent: NSColor = NSColor(hex: 0xdf8a2b) {
        didSet { prog.strokeColor = accent.cgColor }
    }

    /// Elapsed fraction, 0...1.
    var fraction: Double = 0 {
        didSet {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            prog.strokeEnd = CGFloat(min(1, max(0, fraction)))
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        for l in [track, prog] {
            l.fillColor = NSColor.clear.cgColor
            l.lineWidth = lineWidth
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        track.strokeColor = NSColor(white: 0, alpha: 0.10).cgColor
        prog.strokeColor = accent.cgColor
        prog.strokeStart = 0
        prog.strokeEnd = 0
    }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - inset - lineWidth / 2
        let path = CGMutablePath()
        // Non-flipped view: angle 0 = 3 o'clock, +angle is counter-clockwise.
        // Start at the top and sweep clockwise for a full circle.
        path.addArc(center: center,
                    radius: radius,
                    startAngle: .pi / 2,
                    endAngle: .pi / 2 - 2 * .pi,
                    clockwise: true)
        track.frame = bounds
        prog.frame = bounds
        track.path = path
        prog.path = path
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}
