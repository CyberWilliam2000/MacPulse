import SwiftUI
import AppKit

struct PrivacyView: View {
    @ObservedObject var monitor: PrivacyMonitor
    @State private var query = ""
    private let orange = Color(red: 0.76, green: 0.29, blue: 0.06)
    private var records: [PrivacyRecord] {
        monitor.history.records.filter {
            query.isEmpty || [$0.use.application, $0.use.process, $0.use.device, $0.use.kind.rawValue,
                              $0.use.pid.map(String.init) ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("摄像头与麦克风", systemImage: "checkmark.shield").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if let date = monitor.reading?.date {
                        Text(date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Text("只读取使用状态，不录音、不拍摄。每 2 秒检查一次。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let r = monitor.reading {
                    card {
                        Label("麦克风 · " + (r.uses.contains { $0.kind == .microphone } ? "正在使用" : r.audioOK ? "未检测到使用" : "状态不完整"), systemImage: "mic")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(orange)
                        ForEach(r.uses.filter { $0.kind == .microphone }) { use in usage(use) }
                        if !r.audioOK { Text("部分状态无法读取，不能据此判断麦克风空闲。").font(.system(size: 12)).foregroundStyle(.secondary) }
                        if !r.defaultInput.isEmpty { Text("系统默认输入：" + r.defaultInput).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    card {
                        Label("摄像头 · " + (r.uses.contains { $0.kind == .camera } ? "正在使用" : r.cameraOK ? "未检测到使用" : "状态不完整"), systemImage: "camera")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(orange)
                        ForEach(r.cameras, id: \.self) { Text($0).font(.system(size: 12)) }
                        if r.cameras.isEmpty { Text("未读到可见摄像头。").font(.system(size: 12)).foregroundStyle(.secondary) }
                        if !r.cameraOK { Text("部分状态无法读取，不能据此判断摄像头空闲。").font(.system(size: 12)).foregroundStyle(.secondary) }
                        Text("摄像头使用者需点击 Mac 菜单栏的绿色隐私指示点核对；这里无法可靠识别具体应用。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if r.uses.contains(where: { $0.kind == .microphone && $0.device.localizedCaseInsensitiveContains("iPhone") }) {
                        card {
                            Label("iPhone 正在充当麦克风", systemImage: "iphone").font(.system(size: 14, weight: .semibold))
                            Text("这会让手机出现连接画面。若不需要，请在上方应用的音频设置中，将输入设备改为 Mac 内置麦克风。系统默认输入与应用自己的选择可能不同。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                } else { ProgressView("正在查询设备状态…").padding() }
                HStack {
                    Text("使用记录").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("最近 30 天 · 最多 500 条").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                TextField("搜索应用、设备或 PID", text: $query).textFieldStyle(.roundedBorder)
                Text("记录从脉搏运行后开始。时间是首次和最后一次观测，并非精确启停时间；短于采样间隔的使用可能遗漏。摄像头记录不包含应用身份。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let error = monitor.storageError { Text(error).font(.system(size: 12)).foregroundStyle(orange) }
                if records.isEmpty { Text(query.isEmpty ? "暂无使用记录；保持脉搏运行即可开始记录。" : "没有匹配的记录。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 14) }
                LazyVStack(spacing: 9) {
                    ForEach(records) { record in
                        card {
                            usage(record.use)
                            Text("首次观测 \(timestamp(record.firstSeen))\n最后观测 \(timestamp(record.lastSeen))")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(record.finish ?? "最近采样仍在使用").font(.system(size: 11)).foregroundStyle(orange)
                        }
                    }
                }
            }.padding(19)
        }
    }
    private func usage(_ use: DeviceUse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(use.application + " · " + use.kind.rawValue).font(.system(size: 13, weight: .semibold))
            Text(use.device).font(.system(size: 12))
            if let pid = use.pid {
                Text("\(use.process.isEmpty ? "进程" : use.process) · PID \(pid)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.17)))
    }
    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().second())
    }
}
