import SwiftUI
import AppKit

private let listOrange = Color(red: 0.76, green: 0.29, blue: 0.06)
private let listMuted = Color(red: 0.40, green: 0.41, blue: 0.43)
private let listLine = Color(red: 0.87, green: 0.85, blue: 0.82)

struct ApplicationList: View {
    let applications: [Load]
    let paths: [String: String]
    let advice: [Optimization]
    let pending: Set<String>
    let fresh: Bool
    let inspect: (Load) -> Void
    let open: (Load) -> Void
    let quit: (Load) -> Void
    let forceQuit: (Load) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var order = StableApplicationOrder()
    @State private var hoverY: CGFloat?

    var body: some View {
        let apps = order.arranged(applications)
        let cursor = hoverY
        let motionReduced = reduceMotion
        VStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                ApplicationRow(app: app, path: paths[app.id], advice: advice.first { $0.id == app.id },
                               pending: pending.contains(app.id), fresh: fresh,
                               inspect: { inspect(app) }, open: { open(app) }, quit: { quit(app) },
                               forceQuit: { forceQuit(app) })
                    .visualEffect { content, geometry in
                        let center: CGFloat = geometry.frame(in: .named("application-list")).midY
                        let distance: CGFloat = cursor.map { (center - $0) / 90 } ?? 999
                        let strength: CGFloat = cursor == nil ? 0 : CGFloat(exp(-Double(distance * distance)))
                        let displacement: CGFloat = motionReduced ? 0 : strength * 5
                        let scale: CGFloat = motionReduced ? 1 : 1 + strength * 0.006
                        return content.offset(CGSize(width: displacement, height: 0)).scaleEffect(scale)
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72), value: hoverY)
                if index < apps.count - 1 {
                    Rectangle().fill(listLine.opacity(0.65)).frame(height: 0.5).padding(.leading, 76).padding(.trailing, 13)
                }
            }
        }
        .padding(6)
        .coordinateSpace(name: "application-list")
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if hoverY == nil || abs((hoverY ?? 0) - location.y) >= 5 { hoverY = location.y }
            case .ended: hoverY = nil
            }
        }
        .onAppear { order.reconcile(applications.map(\.id)) }
        .onChange(of: applications.map(\.id)) { _, ids in order.reconcile(ids) }
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(listLine.opacity(0.8)))
    }
}

private final class ApplicationIcons {
    static let shared = ApplicationIcons()
    private let cache = NSCache<NSString, NSImage>()
    func image(_ path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
private struct ApplicationRow: View {
    let app: Load
    let path: String?
    let advice: Optimization?
    let pending: Bool
    let fresh: Bool
    let inspect: () -> Void
    let open: () -> Void
    let quit: () -> Void
    let forceQuit: () -> Void
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        switch app.name.lowercased() {
        case "lark", "feishu": return "飞书"
        case "wechat": return "微信"
        default: return app.name
        }
    }
    private var canForce: Bool {
        fresh && path != nil && app.applicationPID != nil && (app.applicationBirth ?? 0) != 0 && !pending
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: open) {
                    Group {
                    if let path {
                        Image(nsImage: ApplicationIcons.shared.image(path)).resizable().interpolation(.high)
                    } else { Image(systemName: "app.fill").resizable().foregroundStyle(listMuted.opacity(0.45)) }
                    }.scaledToFit().frame(width: 48, height: 48)
                }.buttonStyle(.plain).help("打开 " + title).accessibilityLabel("打开 " + title)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("CPU \(percent(app.cpu)) · \(app.members) 个进程")
                        .font(.system(size: 10)).foregroundStyle(listMuted).monospacedDigit()
                    HStack(spacing: 12) {
                        Button("任务", action: inspect).accessibilityLabel("查看 " + title + " 的任务")
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 3) { Text("建议"); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold)) }
                        }.accessibilityLabel((expanded ? "收起 " : "展开 ") + title + " 的建议")
                        Button("正常退出", action: quit).disabled(pending || !fresh)
                            .accessibilityLabel("正常退出 " + title)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(listOrange).buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(size(app.memory)).font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText()).lineLimit(1)
                    Button(role: .destructive, action: forceQuit) {
                        HStack(spacing: 4) {
                            if pending { ProgressView().controlSize(.mini).tint(.white) }
                            Text(pending ? "关闭中…" : "强制关闭")
                        }
                    }
                    .buttonStyle(ForceCloseButton()).disabled(!canForce)
                    .help(canForce ? "立即强制关闭这个应用，未保存内容可能丢失。" : "等待采样确认这个运行实例；也可点正常退出。")
                    .accessibilityLabel("强制关闭 " + title)
                }
            }.padding(.horizontal, 12).padding(.vertical, 16)
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    if let advice {
                        ForEach(Array(advice.steps.enumerated()), id: \.offset) { index, text in
                            Text("\(index + 1). " + text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(advice.evidence).font(.system(size: 10)).foregroundStyle(listMuted)
                    } else {
                        Text("先点「任务」看具体进程。若有不用的预览、独立窗口、下载或导出，优先从应用内结束那一项；整个应用不用时可直接关闭。")
                            .font(.system(size: 11)).foregroundStyle(listMuted)
                    }
                }.padding(.leading, 72).padding(.trailing, 12).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(listOrange.opacity(hovered ? 0.045 : 0)))
        .onHover { hovered = $0 }
    }
}
private struct ForceCloseButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(listOrange.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
