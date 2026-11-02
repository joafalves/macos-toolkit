import AppKit
import SwiftUI

/// Three bars bouncing, shown next to an app that is playing: in the Audio
/// Mixer, and in the Window Switcher with the mixer's driver. Core Animation
/// moves them, outside the app: drawn by SwiftUI each frame, a few rows of
/// them kept the toolkit at about 10% of a core while the mixer was open.
/// A window that isn't on screen isn't drawn, so a hidden one costs nothing.
struct PlayingBars: NSViewRepresentable {
    /// The accent colour when nil.
    var color: NSColor?
    var scale: CGFloat = 1

    func makeNSView(context: Context) -> PlayingBarsView { PlayingBarsView(scale: scale) }
    func updateNSView(_ view: PlayingBarsView, context: Context) { view.color = color }
    // Its own size, not the row's height: the bars stand on the view's bottom.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayingBarsView, context: Context) -> CGSize? { nsView.size }
}

final class PlayingBarsView: NSView {
    private static let width: CGFloat = 2, gap: CGFloat = 1.5, low: CGFloat = 3, high: CGFloat = 9
    /// Seconds from low to high for each bar, so they don't move together.
    private static let periods: [CFTimeInterval] = [0.63, 0.47, 0.37]
    /// Where each bar stands when nothing moves it (snapshots, Reduce Motion).
    private static let resting: [CGFloat] = [6, 9, 4]
    private let scale: CGFloat
    private var bars: [CALayer] = []
    var size: CGSize { CGSize(width: (Self.width * 3 + Self.gap * 2) * scale, height: Self.high * scale) }
    var color: NSColor? {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    init(scale: CGFloat = 1) {
        self.scale = scale
        super.init(frame: .zero)
        frame.size = size
        wantsLayer = true
        for index in 0..<3 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = Self.width * scale / 2
            bar.frame = CGRect(x: CGFloat(index) * (Self.width + Self.gap) * scale, y: 0,
                               width: Self.width * scale, height: Self.resting[index] * scale)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { size }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = (color ?? .controlAccentColor).cgColor
        bars.forEach { $0.backgroundColor = color }
    }

    // Animations go with the layer tree a view leaves, so they're added each
    // time it's put in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bars.forEach { $0.removeAllAnimations() }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (index, bar) in bars.enumerated() {
            let bounce = CABasicAnimation(keyPath: "bounds.size.height")
            bounce.fromValue = Self.low * scale
            bounce.toValue = Self.high * scale
            bounce.duration = Self.periods[index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.timeOffset = Self.periods[index] * Double(index) / 3
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: "bounce")
        }
    }
}
