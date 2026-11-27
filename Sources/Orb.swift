import AppKit
import SwiftUI

struct OrbView: View {
    @ObservedObject var monitor: Monitor
    var open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = 132

    private var latest: Sample? { monitor.samples.last }
    private var pressure: [Metric] { Diagnosis.currentPressure(monitor.samples) }
    private var alerting: Bool { !pressure.isEmpty }
    private var glow: Color {
        alerting ? Color(red: 1, green: 0.74, blue: 0.40) : Color(red: 0.89, green: 0.96, blue: 0.83)
    }
    private var readingColor: Color {
        alerting ? .white : Color(red: 0.08, green: 0.19, blue: 0.12)
    }
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
                Image(systemName: alerting ? "exclamationmark" : "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(alerting ? glow : readingColor)
                    .frame(width: 23, height: 23)
                    .background(.black.opacity(alerting ? 0.20 : 0.10), in: Circle())
                    .overlay { Circle().strokeBorder(glow.opacity(0.31)) }
                    .position(x: 66, y: 66)
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Circle().inset(by: 5))
        }
        .buttonStyle(.plain)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: alerting)
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
        let colors = alerting ? [
            Color(red: 0.64, green: 0.30, blue: 0.035),
            Color(red: 0.29, green: 0.11, blue: 0.026)
        ] : [
            Color(red: 0.85, green: 0.92, blue: 0.73),
            Color(red: 0.64, green: 0.77, blue: 0.51),
            Color(red: 0.38, green: 0.55, blue: 0.42)
        ]
        return Circle()
            .fill(RadialGradient(colors: colors, center: UnitPoint(x: 0.35, y: 0.15),
                                 startRadius: 3, endRadius: 126))
            .overlay {
                if alerting {
                    Circle().fill(RadialGradient(colors: [glow.opacity(0.24), .clear],
                                                 center: UnitPoint(x: 0.67, y: 0.99),
                                                 startRadius: 0, endRadius: 60))
                } else {
                    Circle().fill(EllipticalGradient(
                        colors: [Color(red: 0.79, green: 0.92, blue: 0.84).opacity(0.64), .clear],
                        center: UnitPoint(x: 0.68, y: 0.87), endRadiusFraction: 0.52
                    ))
                    willowHighlights
                }
            }
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(alerting ? 0.62 : 0.50), glow.opacity(0.40),
                                            .black.opacity(alerting ? 0.36 : 0.17), glow.opacity(0.58)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.25
                )
            }
            .overlay {
                Circle().inset(by: 3).trim(from: 0.47, to: 0.71)
                    .stroke(LinearGradient(colors: [.clear, .white.opacity(alerting ? 0.42 : 0.27), .clear],
                                           startPoint: .leading, endPoint: .topTrailing), lineWidth: 1.5)
                    .rotationEffect(.degrees(11))
            }
            .frame(width: 120, height: 120)
            .shadow(color: .black.opacity(0.38), radius: 3, x: 0, y: 2)
            .accessibilityHidden(true)
    }

    private var willowHighlights: some View {
        Canvas { context, size in
            let flecks: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
                (0.23, 0.28, 1.3), (0.31, 0.34, 0.8), (0.77, 0.32, 1.0), (0.24, 0.73, 0.9)
            ]
            for fleck in flecks {
                let r = fleck.radius
                let rect = CGRect(x: fleck.x * size.width - r, y: fleck.y * size.height - r,
                                  width: 2 * r, height: 2 * r)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.53)))
            }
        }
    }

    private func reading(_ metric: Metric, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(metric.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(readingColor.opacity(alerting ? 0.82 : 0.88))
            Text(shortValue(metric))
                .font(.system(size: metric == .disk ? 10 : 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .foregroundStyle(readingColor)
        }
        .frame(width: width)
    }

    private func shortValue(_ metric: Metric) -> String {
        guard let latest else { return "—" }
        switch metric {
        case .cpu: return percent(latest.cpu)
        case .memory:
            return latest.pressure == nil ? "—" : metric.value(latest)
        case .heat:
            return latest.temperature.map { String(format: "%.0f°", $0) } ?? latest.thermalLabel
        case .disk:
            guard let bytes = latest.diskTotal else { return "—" }
            if bytes == 0 { return "0 MB/s" }
            if bytes < miB { return String(format: "%.0f KB/s", max(1, bytes / 1024)) }
            return String(format: bytes < 10 * miB ? "%.1f MB/s" : "%.0f MB/s", bytes / miB)
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
