import AppKit
import SwiftUI
import Combine

final class OrbMotion: ObservableObject {
    @Published var active = false
}

struct OrbView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var motion: OrbMotion
    var open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = 132
    private let ink = Color(red: 0.12, green: 0.30, blue: 0.23)
    private let warm = Color(red: 0.65, green: 0.40, blue: 0.14)
    private var latest: Sample? { monitor.samples.last }
    private var pressure: [Metric] { Diagnosis.currentPressure(monitor.samples) }
    private var alerting: Bool { !pressure.isEmpty }
    private var critical: Bool { latest?.pressure == 4 || (latest?.thermal ?? 0) >= 2 }
    private var status: String {
        guard latest != nil else { return "正在采样" }
        guard alerting else { return "暂无压力信号" }
        return pressure.map { metric in
            guard metric == .memory else { return "\(metric.title)有压力" }
            let memory = (latest?.pressure ?? 0) >= 2 ? metric.value(latest) : "正在交换"
            return "内存：\(memory)"
        }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            ZStack {
                surface
                reading(.cpu, width: 48).position(x: 66, y: 28)
                reading(.memory, width: 48).position(x: 66, y: 104)
                reading(.heat, width: 40).position(x: 31, y: 66)
                reading(.disk, width: 46).position(x: 99, y: 66)
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 0.32, green: 0.61, blue: 0.47))
                        .frame(width: 23, height: 23)
                        .background(.white.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.80), lineWidth: 0.8))
                    if alerting {
                        Circle().fill(Color(red: 0.88, green: 0.65, blue: 0.30))
                            .frame(width: critical ? 6 : 4, height: critical ? 6 : 4)
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 0.6))
                            .offset(x: 0, y: 0)
                    }
                }.position(x: 66, y: 66)
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Circle().inset(by: 5))
        }
        .buttonStyle(.plain)
        .preferredColorScheme(.light)
        .accessibilityLabel("Mac 脉搏，展开看板")
        .accessibilityValue(accessibleReadings)
        .help(status + " · 点击展开，拖动移动")
    }

    private var accessibleReadings: String {
        ([status] + [Metric.cpu, .memory, .heat, .disk].map {
            "\($0.title) \($0.value(latest))"
        }).joined(separator: "，")
    }

    private var surface: some View {
        Circle()
            .fill(LinearGradient(colors: [
                Color(red: 0.97, green: 0.99, blue: 0.91),
                Color(red: 0.88, green: 0.96, blue: 0.79),
                Color(red: 0.74, green: 0.89, blue: 0.75)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                MintWater(paused: reduceMotion || !motion.active)
                    .clipShape(Circle())
            }
            .overlay {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.62), .clear],
                                             center: UnitPoint(x: 0.25, y: 0.12), startRadius: 0, endRadius: 78))
            }
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.95),
                    Color(red: 0.61, green: 0.80, blue: 0.65).opacity(0.40), .white.opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .overlay {
                Circle().inset(by: 4).trim(from: 0.53, to: 0.72)
                    .stroke(.white.opacity(0.70), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(9))
            }
            .frame(width: 120, height: 120)
            .shadow(color: Color(red: 0.24, green: 0.45, blue: 0.32).opacity(0.12), radius: 3, x: 0, y: 2)
            .accessibilityHidden(true)
    }

    private func reading(_ metric: Metric, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(metric.title).font(.system(size: 9, weight: .medium)).foregroundStyle(ink.opacity(0.78))
            Text(shortValue(metric))
                .font(.system(size: metric == .disk ? 10 : 13, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.68)
                .foregroundStyle(pressure.contains(metric) ? warm : ink)
        }.frame(width: width)
    }

    private func shortValue(_ metric: Metric) -> String {
        guard let latest else { return "—" }
        switch metric {
        case .cpu: return percent(latest.cpu)
        case .memory: return latest.pressure == nil ? "—" : metric.value(latest)
        case .heat: return latest.temperature.map { String(format: "%.0f°", $0) } ?? latest.thermalLabel
        case .disk:
            guard let bytes = latest.diskTotal else { return "—" }
            if bytes == 0 { return "0 MB/s" }
            if bytes < miB { return String(format: "%.0f KB/s", max(1, bytes / 1024)) }
            return String(format: bytes < 10 * miB ? "%.1f MB/s" : "%.0f MB/s", bytes / miB)
        }
    }
}

private struct MintWater: NSViewRepresentable {
    let paused: Bool
    func makeNSView(context: Context) -> MintWaterLayerView { MintWaterLayerView() }
    func updateNSView(_ view: MintWaterLayerView, context: Context) { view.setFlowing(!paused) }
}

private final class MintWaterLayerView: NSView {
    private let waves = [CALayer(), CALayer()]
    private let fills = [CAShapeLayer(), CAShapeLayer()]
    private let ridges = [CAShapeLayer(), CAShapeLayer()]
    private var flowing = false
    private var drawnSize = CGSize.zero
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        for i in 0..<2 {
            fills[i].fillColor = i == 0
                ? NSColor(srgbRed: 0.36, green: 0.73, blue: 0.58, alpha: 0.21).cgColor
                : NSColor(srgbRed: 0.35, green: 0.77, blue: 0.73, alpha: 0.23).cgColor
            ridges[i].fillColor = nil
            ridges[i].strokeColor = NSColor.white.withAlphaComponent(i == 0 ? 0.48 : 0.36).cgColor
            ridges[i].lineWidth = 0.85
            waves[i].addSublayer(fills[i])
            waves[i].addSublayer(ridges[i])
            layer?.addSublayer(waves[i])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setFlowing(_ active: Bool) {
        guard flowing != active else { return }
        flowing = active
        if active { installAnimations() }
        else { waves.forEach { $0.removeAnimation(forKey: "water-flow") } }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { waves.forEach { $0.removeAnimation(forKey: "water-flow") } }
        else { installAnimations() }
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, drawnSize != bounds.size else {
            installAnimations(); return
        }
        drawnSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<2 {
            waves[i].removeAnimation(forKey: "water-flow")
            waves[i].frame = CGRect(x: 0, y: 0, width: bounds.width * 3, height: bounds.height)
            fills[i].frame = waves[i].bounds
            ridges[i].frame = waves[i].bounds
            let crest = CGMutablePath()
            let level: CGFloat = i == 0 ? 0.54 : 0.68
            let amplitude: CGFloat = i == 0 ? 4.5 : 3.3
            for step in 0...120 {
                let x = CGFloat(step) / 120 * bounds.width * 3
                let angle = Double(x / bounds.width) * 2 * Double.pi + (i == 0 ? 0 : 1.7)
                let y = bounds.height * level + CGFloat(sin(angle)) * amplitude
                if step == 0 { crest.move(to: CGPoint(x: x, y: y)) }
                else { crest.addLine(to: CGPoint(x: x, y: y)) }
            }
            ridges[i].path = crest
            let fill = crest.mutableCopy()!
            fill.addLine(to: CGPoint(x: bounds.width * 3, y: bounds.height))
            fill.addLine(to: CGPoint(x: 0, y: bounds.height))
            fill.closeSubpath()
            fills[i].path = fill
        }
        CATransaction.commit()
        installAnimations()
    }
    private func installAnimations() {
        guard flowing, window != nil, bounds.width > 0 else { return }
        for i in 0..<2 where waves[i].animation(forKey: "water-flow") == nil {
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = i == 0 ? 0 : -bounds.width
            animation.toValue = i == 0 ? -bounds.width : 0
            animation.duration = i == 0 ? 6 : 8
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            waves[i].add(animation, forKey: "water-flow")
        }
    }
}

final class OrbPanel: NSPanel {
    var openDashboard: (() -> Void)?
    var didMoveOrb: ((NSPoint) -> Void)?
    private var dragStart: (cursor: NSPoint, origin: NSPoint)?
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let point = event.locationInWindow
            let radius: CGFloat = 61
            guard hypot(point.x - frame.width / 2, point.y - frame.height / 2) <= radius else { return }
            dragStart = (convertPoint(toScreen: point), frame.origin)
            dragging = false
        case .leftMouseDragged:
            moveOrb(to: event.locationInWindow)
        case .leftMouseUp:
            guard dragStart != nil else { return }
            moveOrb(to: event.locationInWindow)
            dragStart = nil
            if dragging {
                dragging = false
                restorePlacement(frame.origin)
                didMoveOrb?(frame.origin)
            } else {
                openDashboard?()
            }
        default:
            super.sendEvent(event)
        }
    }

    private func moveOrb(to point: NSPoint) {
        guard let dragStart else { return }
        let cursor = convertPoint(toScreen: point)
        let dx = cursor.x - dragStart.cursor.x
        let dy = cursor.y - dragStart.cursor.y
        guard dragging || hypot(dx, dy) >= 4 else { return }
        dragging = true
        setFrameOrigin(NSPoint(x: dragStart.origin.x + dx, y: dragStart.origin.y + dy))
    }

    func restorePlacement(_ savedOrigin: NSPoint?) {
        let savedFrame = savedOrigin.map { NSRect(origin: $0, size: frame.size) }
        let savedCenter = savedFrame.map { NSPoint(x: $0.midX, y: $0.midY) }
        let target = savedCenter.flatMap { center in NSScreen.screens.first { $0.frame.contains(center) } }
            ?? screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = target?.visibleFrame else { return }
        let fallback = NSPoint(x: visible.maxX - frame.width - 22, y: visible.minY + 24)
        let proposed = savedFrame.flatMap { visible.intersects($0) ? $0.origin : nil } ?? fallback
        setFrameOrigin(fitOrigin(proposed, for: frame.size, within: visible.insetBy(dx: 4, dy: 4)))
    }
}

func fitOrigin(_ origin: NSPoint, for size: NSSize, within area: NSRect) -> NSPoint {
    NSPoint(x: max(area.minX, min(origin.x, area.maxX - size.width)),
            y: max(area.minY, min(origin.y, area.maxY - size.height)))
}
