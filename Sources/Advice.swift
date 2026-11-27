import Foundation

struct MicrophoneHint {
    let pid: Int32
    let birth: UInt64
    let device: String
}
struct Optimization: Identifiable {
    let application: Load
    let metric: Metric
    let title: String
    let evidence: String
    let action: String
    let expected: String
    let priority: Double
    var id: String { application.id }
    var steps: [String] { action.components(separatedBy: "\n").filter { !$0.isEmpty } }
}

enum Advice {
    private static let excluded = Set([
        "Mac 脉搏", "MacPulse", "Finder", "Dock", "loginwindow", "SystemUIServer",
        "WindowServer", "ControlCenter", "NotificationCenter", "活动监视器", "Activity Monitor"
    ])
    private enum AppKind { case browser, agent, wechat, feishu, other }
    private static func kind(_ name: String) -> AppKind {
        let name = name.lowercased()
        if ["wechat", "微信"].contains(where: { name.contains($0) }) { return .wechat }
        if ["lark", "feishu", "飞书"].contains(where: { name.contains($0) }) { return .feishu }
        if ["chatgpt", "codex", "kimi", "claude"].contains(where: { name.contains($0) }) { return .agent }
        if ["chrome", "safari", "firefox", "edge", "arc", "brave"].contains(where: { name.contains($0) }) { return .browser }
        return .other
    }
    private static func steps(for kind: AppKind, metric: Metric) -> [String] {
        switch (kind, metric) {
        case (.agent, .cpu), (.agent, .heat):
            return ["保留当前对话；如果有并行的本地工具、浏览器或编译任务，先暂停一个不急的，保存结果。",
                    "若有正在运行的语音或屏幕共享，确认是否还需要；不用时从应用内结束这一项。"]
        case (.agent, _):
            return ["保留当前对话，先关闭额外打开但已不用的独立窗口；输入框里未发送的内容先保存。",
                    "若启用了语音、视频或屏幕共享，检查是否已结束。历史对话列表不代表都在运行，无需为了腾内存删除聊天记录。"]
        case (.wechat, .disk):
            return ["保留微信在线；在当前传输或下载窗口里，只暂停可以稍后继续的大文件任务。",
                    "不清理聊天记录，也不操作旧版微信的数据目录；调整一项后再比较读写与交换速率。"]
        case (.wechat, _):
            return ["保留微信在线，先关闭已不用的独立图片、视频预览和文件窗口，不关闭正在使用的聊天。",
                    "如果正在播放视频或传输大文件，先暂停一项不急的；双开时分别检查对应客户端。"]
        case (.feishu, .disk):
            return ["保留飞书在线；查看应用里当前的上传、下载或导出列表，只暂停一项可以稍后继续的任务。",
                    "保留正在编辑的内容，避免为了优化去删除文档、消息或缓存。"]
        case (.feishu, _):
            return ["保留消息在线，先关闭一个已不用的独立文档或网页窗口；保存正在编辑的内容。",
                    "若有会议、屏幕共享或视频预览，检查是否仍需要，从飞书内结束已不用的那一项。"]
        case (.browser, .disk):
            return ["保留工作页面，打开浏览器下载列表，只暂停一个不急的大文件下载。",
                    "如果网页正在上传文件，先确认任务是否可以暂停；不要直接关闭正在提交内容的页面。"]
        case (.browser, _):
            return ["保留工作标签页，先暂停一个后台播放的视频、直播或自动刷新的网页。",
                    "记下地址后，关闭一个已不用的重页面或独立窗口；未提交的表单先保存。"]
        case (.other, .disk):
            return ["打开应用，检查当前下载、上传、同步或导出列表；只暂停一项可以稍后继续的任务。",
                    "如果看不到对应任务，先查看具体进程，不根据占用数字结束未知辅助进程。"]
        case (.other, _):
            return ["保留当前工作，先关闭一个已不用的预览或独立窗口，未保存的内容先保存。",
                    "如果正在导出、编译或播放视频，先暂停一项不急的；用途不明时先看具体任务。"]
        }
    }

    static func suggestions(_ samples: [Sample], focus: Metric? = nil,
                            processes: [String: [ProcessReading]] = [:], microphones: [MicrophoneHint] = []) -> [Optimization] {
        guard let latest = samples.last else { return [] }
        var recent = [latest]
        for sample in samples.dropLast().reversed() {
            let gap = recent[0].id.timeIntervalSince(sample.id)
            guard gap > 0 && gap <= 7 && latest.id.timeIntervalSince(sample.id) <= 21 else { break }
            recent.insert(sample, at: 0)
        }
        let pressure = Diagnosis.currentPressure(samples), needsMemory = pressure.contains(.memory)
        let memoryLimit = needsMemory ? 512 * miB : giB
        var result = [Optimization]()
        for app in latest.sources where app.isApplication == true && !excluded.contains(app.name) {
            var observed = [Sample]()
            for sample in recent.reversed() {
                guard sample.sources.contains(where: { $0.id == app.id }) else { break }
                observed.insert(sample, at: 0)
            }
            let duration = observed.first.map { latest.id.timeIntervalSince($0.id) } ?? 0
            let cpus = observed.compactMap { $0.sources.first { $0.id == app.id }?.cpu }
            let averageCPU = cpus.reduce(0,+) / Double(max(1, cpus.count))
            let sustained = observed.count >= 2 && duration >= 3 && averageCPU >= 30 && app.cpu >= 25
            let details = processes[app.id] ?? (latest.processes ?? []).filter { $0.application == app.name }
            let kind = kind(app.name)
            let iphone = microphones.first { hint in
                hint.device.localizedCaseInsensitiveContains("iPhone") && details.contains {
                    $0.pid == hint.pid && $0.birth == hint.birth && hint.birth != 0
                }
            }
            let metric: Metric
            let priority: Double
            if sustained && focus != .memory && focus != .disk {
                metric = .cpu
                priority = (latest.thermal >= 2 || pressure.contains(.cpu) ? 340 : needsMemory ? 210 : 180) + min(averageCPU / 10, 70)
            } else if app.memory >= memoryLimit && (focus == nil || focus == .memory) {
                metric = .memory
                priority = (needsMemory ? 260 : 50) + min(app.memory / giB * 10, 70)
            } else if pressure.contains(.disk), (focus == nil || focus == .disk), app.read + app.write >= 5 * miB {
                metric = .disk; priority = 200
            } else if iphone != nil && focus == nil {
                metric = .cpu; priority = 40
            } else { continue }
            let title: String
            switch kind {
            case .wechat: title = "微信继续在线，先减轻一个小负担"
            case .feishu: title = "保留飞书，先处理闲置窗口或音视频"
            case .agent: title = "保留 \(app.name)，先减轻额外窗口和任务"
            case .browser: title = "保留工作网页，先暂停一个后台页面"
            case .other: title = "保留 \(app.name)，先调整一项小任务"
            }
            var evidence = metric == .memory ? "合计内存约 \(size(app.memory))，\(app.members) 个可读进程。" :
                metric == .disk ? "可归属读写合计 \(rate(app.read + app.write))。" :
                "当前 CPU \(percent(app.cpu))。"
            if metric == .cpu && sustained { evidence += "最近约 \(Int(duration)) 秒平均 CPU \(percent(averageCPU))。" }
            if let leader = details.ranked(for: metric).first {
                evidence += "其中 \(ProcessTasks.describe(leader).title)（PID \(leader.pid)）\(metric == .memory ? "内存" : metric.title) \(leader.display(metric))。"
            }
            var actions = steps(for: kind, metric: metric)
            if let iphone {
                evidence += "同一进程正在使用 \(iphone.device)。"
                actions.insert("如果不需要手机收音，在应用的音频设置中把输入设备切回 Mac 内置麦克风；这里只提示，不自动修改设备。", at: 0)
            }
            let expected = needsMemory
                ? "一次只调整一项，点击「比较效果」观察 30 秒内的占用、交换速率与热压力；释放量以实测为准。"
                : "当前未检测到内存压力升高，可按需调整。关闭窗口是否释放内存取决于应用，随后比较实际读数。"
            result.append(Optimization(application: app, metric: metric, title: title, evidence: evidence,
                                       action: actions.joined(separator: "\n"), expected: expected, priority: priority))
        }
        return Array(result.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            let a = $0.application.value($0.metric), b = $1.application.value($1.metric)
            return a == b ? $0.id < $1.id : a > b
        }.prefix(3))
    }
    static func headline(_ samples: [Sample]) -> String {
        guard let last = samples.last else { return "正在读取当前任务" }
        let pressure = Diagnosis.currentPressure(samples)
        if pressure.contains(.memory) { return "保留常用软件，先减轻一点负担" }
        if last.thermal >= 2 || pressure.contains(.cpu) { return "先暂停一项不急的重任务" }
        if pressure.contains(.disk) { return "先检查正在传输的大文件" }
        if last.thermal == 1 { return "有些发热，看看哪些任务持续忙" }
        return "目前可以继续工作"
    }
    static func text(_ samples: [Sample], focus: Metric? = nil) -> String {
        let items = suggestions(samples, focus: focus)
        guard !items.isEmpty else { return "目前没有足够的应用占用证据生成具体调整建议。卡顿时点「刚刚卡了」保留当时数据。" }
        return items.enumerated().map { index, item in
            "\(index + 1). \(item.application.name)｜\(item.title)\n\(item.evidence)\n\(item.action)\n\(item.expected)"
        }.joined(separator: "\n\n")
    }
}
