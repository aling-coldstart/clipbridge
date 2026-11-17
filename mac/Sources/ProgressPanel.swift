import AppKit

/// Small floating window in the top-right corner that shows one large file transfer:
/// a progress bar, bytes done, speed and time left. Main thread only.
/// `begin` returns a token; updates for an older token are ignored, so a transfer
/// that was superseded can't overwrite the newer one's display.
final class ProgressPanel {
    private static let size = NSSize(width: 340, height: 92)
    private static let margin: CGFloat = 16
    private static let hideDelay: TimeInterval = 3

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    /// Where speed is measured from: the first update with bytes moving.
    private var rateOrigin: (time: Date, bytes: Int64)?
    private var hideWork: DispatchWorkItem?
    private var currentToken = 0

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.titled, .hudWindow, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.title = "ClipBridge"
        panel.level = .floating
        panel.hidesOnDeactivate = false          // we are an accessory app and never active
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1

        let stack = NSStackView(views: [titleLabel, bar, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        panel.contentView = content
    }

    /// Show a new transfer. Without a known size the bar spins until the first update.
    @discardableResult
    func begin(_ title: String, detail: String) -> Int {
        currentToken += 1
        hideWork?.cancel()
        rateOrigin = nil
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        placeTopRight()
        panel.orderFrontRegardless()
        return currentToken
    }

    func update(_ token: Int, done: Int64, total: Int64) {
        guard token == currentToken, total > 0 else { return }
        let clamped = min(max(done, 0), total)
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        bar.doubleValue = Double(clamped) / Double(total)
        if rateOrigin == nil, clamped > 0 { rateOrigin = (Date(), clamped) }
        let percent = Int((Double(clamped) / Double(total) * 100).rounded(.down))
        var parts = ["\(percent)%", "\(formatBytes(clamped)) / \(formatBytes(total))"]
        if let origin = rateOrigin {
            let elapsed = Date().timeIntervalSince(origin.time)
            let rate = elapsed > 0.5 ? Double(clamped - origin.bytes) / elapsed : 0
            if rate > 0 {
                parts.append("\(formatBytes(Int64(rate)))/s")
                parts.append("剩余 \(Self.duration(Double(total - clamped) / rate))")
            }
        }
        detailLabel.stringValue = parts.joined(separator: " · ")
    }

    /// Show the outcome, then hide after a moment.
    func finish(_ token: Int, _ message: String, succeeded: Bool) {
        guard token == currentToken else { return }
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        if succeeded { bar.doubleValue = 1 }
        detailLabel.stringValue = message
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    private func placeTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: screen.maxX - frame.width - Self.margin,
                                     y: screen.maxY - frame.height - Self.margin))
    }

    private static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }
}
