import AppKit
import SwiftUI
import Combine

private let canvas = Color(red: 0.97, green: 0.96, blue: 0.94)
private let panel = Color.white
private let line = Color(red: 0.87, green: 0.85, blue: 0.82)
private let muted = Color(red: 0.40, green: 0.41, blue: 0.43)
private let textColor = Color(red: 0.16, green: 0.17, blue: 0.19)
private let accent = Color(red: 0.76, green: 0.29, blue: 0.06)

extension Metric {
    var icon: String {
        switch self { case .cpu: "cpu"; case .memory: "memorychip"; case .disk: "internaldrive"; case .heat: "thermometer.medium" }
    }
    var tint: Color {
        accent
    }
    func value(_ s: Sample?) -> String {
        guard let s else { return "—" }
        switch self {
        case .cpu: return percent(s.cpu)
        case .memory: return s.pressure == 2 ? "很努力" : s.pressureLabel
        case .disk: return rate(s.diskTotal)
        case .heat: return s.temperature == nil ? s.thermalLabel : degrees(s.temperature)
        }
    }
    func sub(_ s: Sample?) -> String {
        guard let s else { return "正在采样" }
        switch self {
        case .cpu: return "全机占用"
        case .memory: return "交换 " + rate(s.swapTotal)
        case .disk: return "读写合计"
        case .heat: return "热压力 " + s.thermalLabel
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case live = "优化建议", metrics = "性能详情", privacy = "摄像头与麦克风", incidents = "卡顿记录", chat = "问诊"
    var id: Self { self }
}

struct Exchange: Identifiable {
    var id = UUID()
    var question: String
    var answer: String
}

private struct ProcessSelection: Identifiable {
    var group: Load?
    var metric: Metric
    var id: String { group?.id ?? "all" }
}

final class Interface: ObservableObject {
    @Published var page: Page = .live
    @Published var metric: Metric = .cpu
    @Published var marked: Date?
    @Published var chatIncident: Date?
    @Published var pinned = UserDefaults.standard.bool(forKey: "pinned")
    @Published var notice: String?
    @Published var chats = [Exchange]()
    var pinChanged: ((Bool) -> Void)?
    var collapse: (() -> Void)?

    func togglePin() {
        pinned.toggle()
        UserDefaults.standard.set(pinned, forKey: "pinned")
        pinChanged?(pinned)
    }

    func mark(_ monitor: Monitor) {
        guard monitor.mark(), let incident = monitor.incidents.first else {
            notice = "暂时无法保存；请等采样开始后重试。"
            return
        }
        selectIncident(incident)
        chatIncident = incident.id
        page = .incidents
        notice = "已记录 \(clockLabel(incident.id)) 前的采样"
    }

    func selectIncident(_ incident: Incident) {
        marked = incident.id
        metric = Diagnosis.findings(incident.samples).first(where: { $0.level >= 45 })?.metric ?? .cpu
    }

    func answer(_ query: String, _ monitor: Monitor) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let explicitlyNow = ["现在", "此刻", "实时", "当前"].contains { q.contains($0) }
        let justThen = ["刚刚", "刚才", "上次", "那次"].contains { q.contains($0) }
        let selected = monitor.incidents.first { $0.id == chatIncident }
        let event = explicitlyNow ? nil : (selected ?? (justThen ? monitor.incidents.first : nil))
        let label = event.map { "卡顿记录 \(clockLabel($0.id))" } ??
            (justThen && !explicitlyNow ? "尚无卡顿标记；以下是最近采样" : "实时采样")
        let samples = event?.samples ?? monitor.samples
        let recent = samples.last.map { Date().timeIntervalSince($0.id) < 12 } ?? false
        let answer = (event != nil || recent || samples.isEmpty) ? Diagnosis.ask(q, samples: samples, label: label) : "实时读数正在刷新，请等几秒后再问。"
        chats.append(Exchange(question: q, answer: answer))
        if chats.count > 30 { chats.removeFirst() }
        page = .chat
        notice = nil
    }
}

struct PanelRoot: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var privacy: PrivacyMonitor
    @ObservedObject var ui: Interface
    @State private var query = ""
    @FocusState private var typing: Bool
    @State private var confirmRemove = false
    @State private var processSelection: ProcessSelection?
    @StateObject private var applicationActions = ApplicationActions()
    @StateObject private var adjustmentCheck = AdjustmentCheck()

    private var latest: Sample? { monitor.samples.last }
    private var selected: Incident? { monitor.incidents.first { $0.id == ui.marked } ?? monitor.incidents.first }
    private var chatRecord: Incident? { monitor.incidents.first { $0.id == ui.chatIncident } }

    var body: some View {
        VStack(spacing: 0) {
            header
            navigation
            Rectangle().fill(line).frame(height: 1)
            Group {
                switch ui.page {
                case .live: optimization
                case .metrics: live
                case .privacy: PrivacyView(monitor: privacy)
                case .incidents: records
                case .chat: chat
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 505, idealWidth: 556, minHeight: 565, idealHeight: 698)
        .background(canvas)
        .foregroundStyle(textColor)
        .preferredColorScheme(.light)
        .tint(accent)
        .sheet(item: $processSelection) { selection in
            ProcessInspector(monitor: monitor, privacy: privacy, selection: selection)
        }
        .onReceive(monitor.$samples) { adjustmentCheck.accept($0) }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.13))
                Image(systemName: "waveform.path.ecg").font(.system(size: 19, weight: .semibold)).foregroundStyle(accent)
            }.frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mac 脉搏").font(.system(size: 21, weight: .bold))
                Text("桌面性能与卡顿诊断").font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(latest == nil ? muted : accent).frame(width: 6, height: 6)
                Text(latest == nil ? "连接中" : "本机采样")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            Button { ui.togglePin() } label: {
                Image(systemName: ui.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 31, height: 31)
                    .foregroundStyle(ui.pinned ? accent : muted)
                    .background(panel, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(ui.pinned ? "取消置顶" : "窗口置顶")
            .accessibilityLabel(ui.pinned ? "取消置顶" : "窗口置顶")
            Button { ui.collapse?() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 31, height: 31)
                    .foregroundStyle(muted)
                    .background(panel, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("收成小球")
            .accessibilityLabel("收成小球")
        }.padding(.horizontal, 19).padding(.top, 14).padding(.bottom, 17)
    }

    private var navigation: some View {
        HStack(spacing: 18) {
            ForEach(Page.allCases) { page in
                Button {
                    ui.page = page
                    ui.notice = nil
                } label: {
                    VStack(spacing: 9) {
                        Text(page.rawValue)
                            .font(.system(size: 13, weight: ui.page == page ? .semibold : .medium))
                            .foregroundStyle(ui.page == page ? textColor : muted)
                        Capsule().fill(ui.page == page ? accent : .clear).frame(height: 2)
                    }.fixedSize(horizontal: true, vertical: false)
                }.buttonStyle(.plain)
            }
            Spacer()
            if let latest {
                Text(clockLabel(latest.id)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    .padding(.bottom, 8)
            }
        }.padding(.horizontal, 19)
    }

    private var live: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(Metric.allCases) { metric in
                        Button { ui.metric = metric } label: {
                            MetricCard(metric: metric, sample: latest, selected: ui.metric == metric)
                        }.buttonStyle(.plain)
                        .accessibilityLabel("\(metric.title)：\(metric.value(latest))，\(metric.sub(latest))")
                    }
                }
                trend(Array(monitor.samples.suffix(41)), title: "最近 2 分钟")
                currentFinding
                if let latest {
                    processList(latest)
                }
            }.padding(17)
        }
        .scrollIndicators(.automatic)
    }

    private var optimization: some View {
        let microphones: [MicrophoneHint] = privacy.reading.flatMap { reading in
            Date().timeIntervalSince(reading.date) < 6 ? reading.uses.compactMap { use in
                guard use.kind == .microphone, let pid = use.pid, let birth = use.birth else { return nil }
                return MicrophoneHint(pid: pid, birth: birth, device: use.device)
            } : nil
        } ?? []
        let advice = Advice.suggestions(monitor.samples, processes: monitor.processesByGroup, microphones: microphones)
        let fresh = latest.map { Date().timeIntervalSince($0.id) < 12 } ?? false
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(fresh ? Advice.headline(monitor.samples) : "正在读取当前任务")
                        .font(.system(size: 21, weight: .semibold))
                    if let latest, fresh {
                        Text("内存\(latest.pressureLabel) · 交换 \(rate(latest.swapTotal)) · 热压力\(latest.thermalLabel)")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    HStack(spacing: 8) {
                        Button("腾出内存") { ui.chatIncident = nil; ui.answer("内存优化建议，保留常用软件，先调整哪些小任务？", monitor) }
                            .buttonStyle(QuietButton(tint: accent))
                        Button("减少发热") { ui.chatIncident = nil; ui.answer("发热优化建议，先暂停哪个任务？", monitor) }
                            .buttonStyle(QuietButton(tint: accent))
                        Spacer()
                    }
                }.padding(14).block()

                if let message = applicationActions.message {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).block()
                }
                if let message = adjustmentCheck.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).block()
                }
                if fresh && !advice.isEmpty {
                    ForEach(advice) { item in
                        OptimizationCard(
                            item: item,
                            quitting: applicationActions.pendingIDs.contains(item.id),
                            comparing: adjustmentCheck.current?.app.id == item.id,
                            inspect: {
                            processSelection = ProcessSelection(group: item.application, metric: item.metric)
                            },
                            open: {
                                let fresh = latest.map { Date().timeIntervalSince($0.id) < 12 } ?? false
                                applicationActions.open(item.application, path: monitor.applicationPaths[item.id], fresh: fresh)
                            },
                            compare: { adjustmentCheck.begin(item.application, samples: monitor.samples) },
                            quit: {
                                let fresh = latest.map { Date().timeIntervalSince($0.id) < 12 } ?? false
                                applicationActions.quit(item.application, path: monitor.applicationPaths[item.id], fresh: fresh)
                            }
                        )
                    }
                    Text("内存数字是当前占用估计。你可以先调整一项，再比较卡顿、交换速率与热压力的变化。")
                        .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fresh ? "暂时没有明确需要调整的大任务" : "等下一次采样后生成建议")
                            .font(.system(size: 15, weight: .semibold))
                        Text(fresh ? "卡顿刚发生时，点「刚刚卡了」保存当时占用。也可以查看全部进程。" :
                                "建议会结合当前占用、持续负载和内存压力更新。")
                            .font(.system(size: 12)).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).block()
                }
                HStack {
                    Button("全部进程") { processSelection = ProcessSelection(metric: .memory) }
                        .buttonStyle(QuietButton(tint: accent))
                    Spacer()
                    Button("查看性能走势") { ui.page = .metrics }.buttonStyle(QuietButton())
                }
            }.padding(17)
        }
    }

    private var currentFinding: some View {
        let finding = Diagnosis.findings(monitor.samples).first
        let warming = (monitor.samples.count < 3)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("诊断线索", systemImage: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(finding.map { $0.level >= 45 ? accent : accent } ?? accent)
                Spacer()
                Button { ui.chatIncident = nil; ui.answer("为什么卡顿？", monitor) } label: {
                    Label("问为什么", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                }.buttonStyle(.plain)
            }
            Text(warming ? "正在建立采样基线" : finding?.title ?? "暂未发现明确的卡顿线索")
                .font(.system(size: 15, weight: .semibold))
            Text(warming ? "约每 3 秒采一次。卡顿刚发生时，点下方按钮保留前几分钟的数据。" : finding?.evidence ?? "如果你感觉卡顿，做一次标记。系统会保留当时能读到的 CPU、内存、磁盘和热压力。")
                .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }.padding(12).block()
    }

    private func trend(_ samples: [Sample], title: String) -> some View {
        let metric = ui.metric
        let s = samples.last
        let hasDegrees = samples.contains { $0.temperature != nil }
        let titleExtra: String = switch metric {
        case .cpu: "全机负载"
        case .memory: "实时交换读写"
        case .disk: "磁盘读写"
        case .heat: hasDegrees ? "内部温度" : "系统热压力"
        }
        let unit: String = switch metric {
        case .cpu: "%"
        case .memory, .disk: "MB/s"
        case .heat: hasDegrees ? "°C" : "等级"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(titleExtra).font(.system(size: 13, weight: .semibold))
                if metric == .heat, let s {
                    Text("热压力 \(s.thermalLabel)").font(.system(size: 10)).foregroundStyle(accent)
                }
                Spacer()
                Text(title).font(.system(size: 10)).foregroundStyle(muted)
            }
            Sparkline(samples: samples, metric: metric, hasDegrees: hasDegrees, unit: unit)
                .frame(height: 87)
            HStack {
                Text(samples.first.map { clockLabel($0.id) } ?? "等待采样")
                Spacer()
                Text(s.map { clockLabel($0.id) } ?? "—")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
            if metric == .heat {
                let note = s?.sensor.map { "最高读数来自 \($0)；显示的是内部温度。" } ?? "摄氏温度未读到；热压力由 macOS 提供。"
                Text(note).font(.system(size: 10)).foregroundStyle(muted)
            }
        }.padding(12).block()
    }

    private func processList(_ s: Sample, live: Bool = true) -> some View {
        let metric = ui.metric
        let leaders = Array(s.ranking(metric).prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric == .heat ? "同期 CPU 榜" : "\(metric.title) 占用榜")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("可读进程 \(s.readable)/\(s.listed)")
                    .font(.system(size: 10)).foregroundStyle(muted)
                if live {
                    Button("全部进程") { processSelection = ProcessSelection(metric: metric) }
                        .buttonStyle(QuietButton(tint: accent))
                }
            }
            if leaders.isEmpty {
                Text(s.readable == 0 ? "进程数据暂不可用" : "这一刻没有可归属的读数")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            ForEach(Array(leaders.enumerated()), id: \.offset) { index, load in
                if live {
                    Button {
                        processSelection = ProcessSelection(group: load, metric: metric)
                    } label: {
                        loadRow(load, number: index + 1, metric: metric, clickable: true)
                    }.buttonStyle(.plain)
                    .accessibilityLabel("查看 \(load.name) 的进程")
                } else {
                    loadRow(load, number: index + 1, metric: metric, clickable: false)
                }
            }
            Text(metric == .cpu || metric == .heat ? "100% ≈ 一个逻辑核心；同期 CPU 使用不能直接归因为发热。" : metric == .memory ? "按应用合并可读进程；数值为内存占用估计。" : "应用榜与全机读写统计口径不同；系统 I/O 未必可归属。")
                .font(.system(size: 10)).foregroundStyle(muted)
            if metric == .disk {
                Text("启动盘可用 \(size(s.free)) · " + (s.diskMS.map { String(format: "平均 I/O 用时 %.1f ms", $0) } ?? "平均 I/O 用时 —"))
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
        }.padding(12).block()
    }

    private func loadRow(_ load: Load, number: Int, metric: Metric, clickable: Bool) -> some View {
        HStack(spacing: 9) {
            Text(String(format: "%02d", number))
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(metric.tint)
            Text(load.name).lineLimit(1).font(.system(size: 12, weight: .medium))
            if load.members > 1 {
                Text("\(load.members) 个进程").font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer()
            Text(metric == .memory ? size(load.memory) : metric == .disk ? rate(load.read + load.write) : percent(load.cpu))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
            if clickable { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(accent) }
        }.padding(.vertical, 3).contentShape(Rectangle())
    }

    @ViewBuilder private func recordedProcesses(_ record: Incident) -> some View {
        if let evidence = Diagnosis.processEvidence(ui.metric, in: record.samples) {
            let metric = ui.metric
            let title = metric == .heat ? "同期 CPU 进程" : "\(metric.title) 进程"
            let readings = (evidence.sample.processes ?? []).ranked(for: metric)
                .filter { ($0.value(metric) ?? 0) > 0 }.prefix(5)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(evidence.duringPressure ? "压力采样" : "标记前最后一帧") · \(clockLabel(evidence.sample.id))")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                if evidence.sample.processes == nil {
                    Text("这条旧记录只保留了应用占用。").font(.system(size: 11)).foregroundStyle(muted)
                } else if readings.isEmpty {
                    Text("这次采样没有可归属的进程读数。").font(.system(size: 11)).foregroundStyle(muted)
                } else {
                    ForEach(readings) { reading in
                        HStack {
                            ProcessIdentity(reading: reading, showApplication: true)
                            Spacer()
                            Text(reading.display(metric))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(metric.tint)
                        }
                    }
                    Text("按这次采样的占用排序。可结合卡顿前后变化，判断先检查哪个任务。")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }.padding(12).block()
        }
    }

    private var records: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let record = selected {
                    HStack {
                        Menu {
                            ForEach(monitor.incidents) { item in
                                Button(item.id.formatted(date: .abbreviated, time: .standard)) { ui.selectIncident(item) }
                            }
                        } label: {
                            Label(record.id.formatted(date: .abbreviated, time: .standard), systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .semibold))
                        }.menuStyle(.borderlessButton).fixedSize()
                        Spacer()
                        Button { ui.chatIncident = record.id; ui.answer("刚才卡顿是为什么？", monitor) } label: {
                            Label("问这次卡顿", systemImage: "bubble.left")
                        }.buttonStyle(QuietButton(tint: accent))
                    }
                    let findings = Diagnosis.findings(record.samples)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("标记前的线索").font(.system(size: 14, weight: .semibold))
                        if findings.isEmpty {
                            Text("这段采样没有足够证据确定主因。卡顿时间很短时，3 秒采样可能错过尖峰。")
                                .font(.system(size: 12)).foregroundStyle(muted)
                        }
                        ForEach(findings) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(item.metric.tint)
                                Text(item.evidence + "\n" + item.action).font(.system(size: 11)).foregroundStyle(muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).block()
                    metricPicker
                    recordedProcesses(record)
                    let signals = Diagnosis.timeline(record.samples)
                    if !signals.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("这段记录里的信号先后").font(.system(size: 13, weight: .semibold))
                            ForEach(signals) { signal in
                                HStack(spacing: 9) {
                                    Text(clockLabel(signal.date)).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(signal.metric.tint)
                                    Text(signal.label).font(.system(size: 11)).foregroundStyle(muted)
                                }
                            }
                            Text("时间为首次采到；先后顺序不等于因果。").font(.system(size: 10)).foregroundStyle(muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).block()
                    }
                    trend(record.samples, title: "标记前 · \(record.samples.count) 个采样点")
                    if let evidence = Diagnosis.processEvidence(ui.metric, in: record.samples) {
                        processList(evidence.sample, live: false)
                    }
                    HStack {
                        Button {
                            copy(Diagnosis.report(record.samples, label: "卡顿记录 \(clockLabel(record.id))"))
                            ui.notice = "已复制诊断摘要"
                        } label: { Label("复制诊断摘要", systemImage: "doc.on.doc") }.buttonStyle(QuietButton())
                        Spacer()
                        Button { confirmRemove = true } label: { Label("删除这条", systemImage: "trash") }
                            .buttonStyle(QuietButton())
                    }
                    .alert("删除这条卡顿记录？", isPresented: $confirmRemove) {
                        Button("取消", role: .cancel) {}
                        Button("删除", role: .destructive) {
                            if monitor.remove(record.id) {
                                if ui.chatIncident == record.id { ui.chatIncident = nil }
                                ui.marked = monitor.incidents.first?.id
                                ui.notice = "已删除记录"
                            } else { ui.notice = "删除未保存，请重试。" }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 11) {
                        Image(systemName: "clock.badge.exclamationmark").font(.system(size: 27, weight: .light)).foregroundStyle(accent)
                        Text("还没有标记过卡顿").font(.system(size: 19, weight: .semibold))
                        Text("刚卡完就点「刚刚卡了」。小窗会保存之前最多 5 分钟的采样，方便回看发热、CPU 与交换内存的变化。")
                            .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(4)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(19).block()
                }
            }.padding(17)
        }
    }

    private var metricPicker: some View {
        HStack(spacing: 7) {
            ForEach(Metric.allCases) { metric in
                Button { ui.metric = metric } label: { Label(metric.title, systemImage: metric.icon) }
                    .buttonStyle(QuietButton(tint: ui.metric == metric ? metric.tint : muted))
            }
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(chatRecord.map { "卡顿记录 · \(clockLabel($0.id))" } ?? "实时采样", systemImage: "target")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                Spacer()
                if chatRecord != nil {
                    Button("切回实时") { ui.chatIncident = nil }.buttonStyle(QuietButton())
                }
                Button {
                    copy(Diagnosis.report(chatRecord?.samples ?? monitor.samples, label: chatRecord == nil ? "实时采样" : "卡顿记录"))
                    ui.notice = "已复制诊断摘要"
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(QuietButton()).help("复制诊断摘要")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        if ui.chats.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("想弄清哪一项？").font(.system(size: 19, weight: .semibold))
                                Text("问诊用这台 Mac 的采样数据回答。可以问为什么发热、谁在占内存，以及先暂停什么任务。")
                                    .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(3)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(15).block()
                        }
                        ForEach(ui.chats) { msg in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Spacer(minLength: 35)
                                    Text(msg.question).font(.system(size: 12, weight: .medium))
                                        .padding(9).background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                                }
                                Text(msg.answer)
                                    .font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).block()
                            }.id(msg.id)
                        }
                    }.padding(.bottom, 2)
                }
                .onChange(of: ui.chats.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                .onAppear { if let id = ui.chats.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack(spacing: 6) {
                ForEach(["是不是发热？", "谁占内存？", "先查什么？"], id: \.self) { prompt in
                    Button(prompt) { ui.answer(prompt, monitor) }.buttonStyle(QuietButton())
                }
            }
            HStack(spacing: 7) {
                TextField("例如：刚刚卡顿是因为磁盘吗？", text: $query)
                    .font(.system(size: 12)).textFieldStyle(.plain).focused($typing)
                    .padding(9).block().onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canvas).frame(width: 31, height: 31)
                        .background(query.trimmingCharacters(in: .whitespaces).isEmpty ? muted : accent, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityLabel("发送问题")
            }
            Text("本机规则问答 · 采样不会上传")
                .font(.system(size: 10)).foregroundStyle(muted)
        }.padding(17)
    }

    private func send() {
        ui.answer(query, monitor)
        query = ""
    }

    private var footer: some View {
        HStack {
            Text(ui.notice ?? "每 3 秒采样 · 标记前最多 5 分钟")
                .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            Spacer()
            Button { ui.mark(monitor) } label: {
                Label("刚刚卡了", systemImage: "flag.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canvas)
                    .padding(.vertical, 8).padding(.horizontal, 13)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .disabled(monitor.samples.isEmpty)
        }
        .padding(.horizontal, 17).padding(.vertical, 11)
        .background(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct OptimizationCard: View {
    let item: Optimization
    var quitting: Bool
    var comparing: Bool
    var inspect: () -> Void
    var open: () -> Void
    var compare: () -> Void
    var quit: () -> Void

    private var category: String {
        switch item.metric {
        case .memory: return "释放内存"
        case .disk: return "减少读写"
        case .cpu, .heat: return "减轻计算负载"
        }
    }

    private var usage: String {
        switch item.metric {
        case .memory: return "当前占用 " + size(item.application.memory)
        case .disk: return rate(item.application.read + item.application.write)
        case .cpu, .heat: return "当前 CPU " + percent(item.application.cpu)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(category, systemImage: item.metric.icon)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(item.metric.tint)
                Spacer()
                Text(usage).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            }
            Text(item.title).font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(item.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text(String(index + 1)).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    Text(step).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(item.evidence).font(.system(size: 11)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                Button("打开 " + item.application.name, action: open).buttonStyle(OrangeButton())
                Button("具体任务", action: inspect).buttonStyle(QuietButton())
                Spacer(minLength: 0)
                Menu("其他") {
                    Text("仅在整个应用暂时不用时")
                    Button(quitting ? "正在退出…" : "正常退出 " + item.application.name, action: quit).disabled(quitting)
                }.font(.system(size: 11)).fixedSize()
            }
            Button(comparing ? "正在观察…" : "比较效果（先点，再调整）", action: compare)
                .buttonStyle(QuietButton()).disabled(comparing)
            Text(item.expected).font(.system(size: 10)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(14).block()
    }
}

private struct ProcessIdentity: View {
    var reading: ProcessReading
    var showApplication: Bool

    private var subtitle: String {
        let application = showApplication && reading.application != reading.name ? reading.application : nil
        return ["PID \(reading.pid)", application, reading.role].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reading.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
        }
        .help(reading.name + " · " + subtitle)
    }
}

private struct ProcessInspector: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var privacy: PrivacyMonitor
    var selection: ProcessSelection
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var sort: Metric
    @State private var expandedPID: Int32?

    init(monitor: Monitor, privacy: PrivacyMonitor, selection: ProcessSelection) {
        self.monitor = monitor
        self.privacy = privacy
        self.selection = selection
        _sort = State(initialValue: selection.metric == .heat ? .cpu : selection.metric)
    }

    var body: some View {
        let available = selection.group.map { monitor.processesByGroup[$0.id] ?? [] }
            ?? monitor.processesByGroup.values.flatMap { $0 }
        let filter = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let readings = available.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) ||
                $0.application.localizedCaseInsensitiveContains(filter) || String($0.pid).contains(filter)
                || ProcessTasks.describe($0).title.localizedCaseInsensitiveContains(filter)
        }.ranked(for: sort)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.group?.name ?? "全部进程").font(.system(size: 18, weight: .semibold))
                    Text("\(available.count) 个可读进程 · " + (monitor.samples.last.map { clockLabel($0.id) } ?? "采样中"))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
            }
            if selection.group != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("内存主要用在哪里").font(.system(size: 12, weight: .semibold))
                    ForEach(ProcessTasks.totals(available).prefix(3)) { total in
                        HStack {
                            Text(total.task.title + " · \(total.count) 个进程")
                            Spacer()
                            Text(size(total.memory)).monospacedDigit().foregroundStyle(accent)
                        }.font(.system(size: 11))
                    }
                    Text("点任一行查看任务说明、占用变化与处理建议。具体文档和聊天名称尚无法识别。")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }.padding(11).block()
            }
            TextField("搜索任务类型、进程名、应用或 PID", text: $search)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text("进程").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                Spacer(minLength: 0)
                sortButton(.cpu, width: 58)
                sortButton(.memory, width: 69)
                sortButton(.disk, width: 83)
            }.padding(.horizontal, 8)
            ScrollView {
                if readings.isEmpty {
                    Text(filter.isEmpty ? "当前没有读到这些进程。" : "没有匹配的进程。")
                        .font(.system(size: 12)).foregroundStyle(muted)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVStack(spacing: 0) {
                    ForEach(readings) { reading in
                        Button {
                            expandedPID = expandedPID == reading.pid ? nil : reading.pid
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 4) {
                                        Image(systemName: expandedPID == reading.pid ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 8)).foregroundStyle(accent)
                                        Text(ProcessTasks.describe(reading).title).font(.system(size: 12, weight: .semibold))
                                    }
                                    ProcessIdentity(reading: reading, showApplication: true)
                                }
                                Spacer(minLength: 0)
                                readingCell(reading, for: .cpu, width: 58)
                                readingCell(reading, for: .memory, width: 69)
                                readingCell(reading, for: .disk, width: 83)
                            }.padding(.horizontal, 8).padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("查看任务：" + ProcessTasks.describe(reading).title + "，PID " + String(reading.pid))
                        if expandedPID == reading.pid { taskDetails(reading) }
                        Divider().overlay(line)
                    }
                }
            }
            .block()
            Text("CPU 的 100% 约等于一个逻辑核心。读数显示「—」时，正在等待下一次采样。")
                .font(.system(size: 10)).foregroundStyle(muted)
        }
        .padding(16).frame(width: 556, height: 590)
        .background(canvas).foregroundStyle(textColor)
    }

    private func taskDetails(_ reading: ProcessReading) -> some View {
        let task = ProcessTasks.describe(reading)
        let fresh = monitor.samples.last.map { Date().timeIntervalSince($0.id) < 8 } ?? false
        let devices = privacy.reading.flatMap { snapshot in
            Date().timeIntervalSince(snapshot.date) < 6 ? snapshot.uses.filter {
                $0.kind == .microphone && $0.pid == reading.pid && $0.birth != nil && $0.birth == reading.birth
            } : nil
        } ?? []
        var evidence = [task.evidence]
        if let service = reading.taskService { evidence.append("服务：" + service) }
        if let renderer = reading.rendererID { evidence.append("渲染编号：" + renderer + "（不是文档名称）") }
        if let parent = reading.parentPID { evidence.append("父进程 PID " + String(parent)) }
        let evidenceText = evidence.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(task.explanation).font(.system(size: 12))
            Text(fresh ? ProcessTasks.impact(reading, trace: monitor.processTraces[reading.pid] ?? []) : "采样正在刷新；当前读数可能已过时。")
                .font(.system(size: 11)).foregroundStyle(muted)
            ForEach(devices) { device in
                Label("正在使用麦克风：" + device.device, systemImage: "mic.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
            }
            Text("可以怎么处理：" + task.action).font(.system(size: 11))
            Text(evidenceText)
                .font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(accent.opacity(0.045))
    }

    private func sortButton(_ metric: Metric, width: CGFloat) -> some View {
        Button { sort = metric } label: {
            HStack(spacing: 4) {
                Text(metric.title)
                if metric == sort { Image(systemName: "arrow.down").font(.system(size: 8)) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(metric == sort ? metric.tint : muted)
            .frame(width: width, alignment: .trailing)
        }.buttonStyle(.plain)
        .accessibilityLabel("按\(metric.title)排序")
    }

    private func readingCell(_ reading: ProcessReading, for metric: Metric, width: CGFloat) -> some View {
        Text(reading.display(metric))
            .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
            .foregroundStyle(metric == sort ? metric.tint : textColor)
            .lineLimit(1).minimumScaleFactor(0.72)
            .frame(width: width, alignment: .trailing)
    }
}

private extension View {
    func block() -> some View {
        background(panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct QuietButton: ButtonStyle {
    var tint: Color = accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(tint.opacity(configuration.isPressed ? 0.20 : 0.09), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct OrangeButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricCard: View {
    var metric: Metric
    var sample: Sample?
    var selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(metric.title, systemImage: metric.icon).font(.system(size: 11, weight: .medium)).foregroundStyle(metric.tint)
            Text(metric.value(sample)).font(.system(size: 19, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.62).monospacedDigit()
            Text(metric.sub(sample)).font(.system(size: 9)).foregroundStyle(muted)
                .lineLimit(1).minimumScaleFactor(0.68)
        }.padding(.horizontal, 9).padding(.vertical, 10)
         .frame(maxWidth: .infinity, alignment: .leading)
         .background(selected ? metric.tint.opacity(0.12) : panel, in: RoundedRectangle(cornerRadius: 10))
         .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? metric.tint.opacity(0.70) : line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct Sparkline: View {
    var samples: [Sample]
    var metric: Metric
    var hasDegrees: Bool
    var unit: String
    private func value(_ s: Sample) -> Double? {
        switch metric {
        case .cpu: s.cpu
        case .memory: s.swapTotal.map { $0 / miB }
        case .disk: s.diskTotal.map { $0 / miB }
        case .heat: hasDegrees ? s.temperature : Double(s.thermal)
        }
    }

    var body: some View {
        let maxValue = samples.compactMap(value).max() ?? 0
        let span: ClosedRange<Double> = switch metric {
        case .cpu: 0...100
        case .memory, .disk: 0...max(5, ceil(maxValue / 5) * 5)
        case .heat: hasDegrees ? 20...max(100, ceil(maxValue / 10) * 10) : 0...3
        }
        HStack(spacing: 5) {
            Canvas { context, size in
                let h = size.height - 8
                let w = size.width - 4
                var grid = Path()
                for j in 0...3 {
                    let y = 4 + h * Double(j) / 3
                    grid.move(to: CGPoint(x: 2, y: y))
                    grid.addLine(to: CGPoint(x: 2 + w, y: y))
                }
                context.stroke(grid, with: .color(line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                guard let first = samples.first, let last = samples.last else { return }
                let time = max(last.id.timeIntervalSince(first.id), 1)
                var path = Path()
                var previous: Date?
                var endpoint: CGPoint?
                for s in samples {
                    guard let v = value(s) else { previous = nil; endpoint = nil; continue }
                    let u = min(1, max(0, (v - span.lowerBound) / (span.upperBound - span.lowerBound)))
                    let point = CGPoint(x: 2 + w * s.id.timeIntervalSince(first.id) / time, y: 4 + h * (1 - u))
                    if let previous, s.id.timeIntervalSince(previous) < 9 { path.addLine(to: point) }
                    else {
                        path.move(to: point)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(metric.tint))
                    }
                    previous = s.id
                    endpoint = point
                }
                context.stroke(path, with: .color(metric.tint), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                if let p = endpoint {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(metric.tint))
                }
            }.accessibilityHidden(true)
            VStack(alignment: .trailing) {
                Text("\(Int(span.upperBound)) \(unit)")
                Spacer()
                Text("\(Int(span.lowerBound))")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum Surface { case compact, expanded, hidden }

    let monitor = Monitor()
    let privacy = PrivacyMonitor()
    let ui = Interface()
    private var window: NSWindow!
    private var orb: OrbPanel!
    private var status: NSStatusItem!
    private var dashboardItem: NSMenuItem!
    private var visibilityItem: NSMenuItem!
    private var surface: Surface = .compact
    private var menuObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpDashboard()
        setUpOrb()
        setUpMenu()
        monitor.start()
        privacy.start()
        if CommandLine.arguments.contains("--privacy") { ui.page = .privacy; showDashboard() }
        else if CommandLine.arguments.contains("--dashboard") { ui.page = .metrics; showDashboard() }
        else { showOrb() }
    }

    private func setUpDashboard() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 556, height: 698),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Mac 脉搏"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(canvas)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 505, height: 592)
        window.delegate = self
        let host = NSHostingView(rootView: PanelRoot(monitor: monitor, privacy: privacy, ui: ui))
        let frame = NSView()
        window.contentView = frame
        host.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            host.topAnchor.constraint(equalTo: frame.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: frame.bottomAnchor)
        ])
        window.level = ui.pinned ? .floating : .normal
        ui.pinChanged = { [weak self] pinned in self?.window.level = pinned ? .floating : .normal }
        ui.collapse = { [weak self] in self?.showOrb() }
        if !window.setFrameUsingName("MacPulsePanel") { window.center() }
        window.setFrameAutosaveName("MacPulsePanel")
    }

    private func setUpOrb() {
        let side = OrbView.side
        orb = OrbPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        orb.title = "Mac 脉搏 · 小球"
        orb.backgroundColor = .clear
        orb.isOpaque = false
        orb.hasShadow = false
        orb.isFloatingPanel = true
        orb.hidesOnDeactivate = false
        orb.becomesKeyOnlyIfNeeded = true
        orb.level = .floating
        orb.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        orb.isReleasedWhenClosed = false
        orb.contentView = NSHostingView(rootView: OrbView(monitor: monitor) { [weak self] in
            self?.showDashboard()
        })
        orb.openDashboard = { [weak self] in self?.showDashboard() }
        orb.didMoveOrb = { point in
            UserDefaults.standard.set(NSStringFromPoint(point), forKey: "orbOrigin")
        }
        let saved = UserDefaults.standard.string(forKey: "orbOrigin").map(NSPointFromString)
        orb.restorePlacement(saved)
    }

    private func setUpMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Mac 脉搏")
        status.button?.imagePosition = .imageLeading
        status.button?.toolTip = "Mac 脉搏"
        let menu = NSMenu()
        @discardableResult func add(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        dashboardItem = add("展开看板", #selector(toggleDashboard))
        visibilityItem = add("隐藏小球", #selector(toggleVisibility))
        add("刚刚卡了", #selector(markNow))
        add("摄像头与麦克风", #selector(showPrivacy))
        add("看板置顶 / 取消置顶", #selector(togglePin))
        menu.addItem(.separator())
        add("退出 Mac 脉搏", #selector(quit), "q")
        status.menu = menu
        menuObservation = monitor.$samples.sink { [weak self] samples in
            guard let self, let current = samples.last, let button = self.status.button else { return }
            let text = current.temperature.map { degrees($0) } ?? "热压 " + current.thermalLabel
            button.title = text
            button.toolTip = "Mac 脉搏 · CPU \(percent(current.cpu)) · 内存：\(Metric.memory.value(current)) · 热压力\(current.thermalLabel)"
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if surface == .expanded { showDashboard() }
        else { showOrb() }
        return true
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard let orb else { return }
        orb.restorePlacement(orb.frame.origin)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        showOrb()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        showOrb()
    }

    @objc private func toggleDashboard() {
        if surface == .expanded { showOrb() }
        else { showDashboard() }
    }

    @objc private func toggleVisibility() {
        if surface == .hidden {
            showOrb()
        } else {
            surface = .hidden
            window.orderOut(nil)
            orb.orderOut(nil)
            updateMenu()
        }
    }

    @objc private func markNow() { ui.mark(monitor); showDashboard() }
    @objc private func showPrivacy() { ui.page = .privacy; showDashboard() }
    @objc private func togglePin() { ui.togglePin() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { privacy.save() }

    private func showOrb() {
        surface = .compact
        window.orderOut(nil)
        orb.orderFrontRegardless()
        updateMenu()
    }

    private func showDashboard() {
        if surface != .expanded, let visible = (orb.screen ?? NSScreen.main)?.visibleFrame {
            let size = window.frame.size
            let x = orb.frame.midX < visible.midX ? orb.frame.minX : orb.frame.maxX - size.width
            let origin = NSPoint(x: x, y: orb.frame.midY - size.height / 2)
            window.setFrameOrigin(fitOrigin(origin, for: size, within: visible.insetBy(dx: 8, dy: 8)))
        }
        surface = .expanded
        orb.orderOut(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateMenu()
    }

    private func updateMenu() {
        dashboardItem.title = surface == .expanded ? "收成小球" : "展开看板"
        switch surface {
        case .compact: visibilityItem.title = "隐藏小球"
        case .expanded: visibilityItem.title = "隐藏看板"
        case .hidden: visibilityItem.title = "显示小球"
        }
    }
}

@main struct MacPulse {
    static func main() {
        if CommandLine.arguments.contains("--tasks-probe") {
            let sampler = Sampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 1)
            _ = sampler.sample()
            let processes = sampler.processesByGroup.values.flatMap { $0 }
            let args = CommandLine.arguments
            let index = args.firstIndex(of: "--tasks-probe")!
            let target = index + 1 < args.count ? args[index + 1] : nil
            for p in processes.filter({ target == nil || $0.application.localizedCaseInsensitiveContains(target!) }).ranked(for: .memory).prefix(50) {
                print("PID \(p.pid) · \(ProcessTasks.describe(p).title) · \(p.name) · 内存 \(size(p.memory)) · CPU \(p.display(.cpu))")
                print("type=\(p.taskType ?? "unknown") service=\(p.taskService ?? "—") renderer=\(p.rendererID ?? "—")")
            }
            return
        }
        if CommandLine.arguments.contains("--privacy-probe") {
            let r = readPrivacy()
            print("Microphone status complete: \(r.audioOK); camera status complete: \(r.cameraOK)")
            print("Default input: \(r.defaultInput)")
            for use in r.uses { print("\(use.kind.rawValue): \(use.application) / \(use.process) / PID \(use.pid ?? 0) / \(use.device)") }
            for camera in r.cameras { print(camera) }
            return
        }
        if CommandLine.arguments.contains("--probe") {
            let sampler = Sampler()
            let cpuStart = Date()
            let first = sampler.sample()
            let duration = Date().timeIntervalSince(cpuStart)
            Thread.sleep(forTimeInterval: 1)
            let sample = sampler.sample()
            print(Diagnosis.report([first, sample], label: "本机采样"))
            print(String(format: "首轮采样耗时：%.0f ms", duration * 1_000))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
