import Foundation

struct ProcessObservation {
    let date: Date
    let reading: ProcessReading
}

struct StableApplicationOrder {
    private(set) var ids: [String] = []
    mutating func reconcile(_ next: [String]) {
        let live = Set(next)
        ids.removeAll { !live.contains($0) }
        let known = Set(ids)
        ids.append(contentsOf: next.filter { !known.contains($0) })
    }
    func arranged(_ apps: [Load]) -> [Load] {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return apps.sorted {
            let a = positions[$0.id] ?? Int.max, b = positions[$1.id] ?? Int.max
            return a == b ? ($0.memory == $1.memory ? $0.id < $1.id : $0.memory > $1.memory) : a < b
        }
    }
}
struct ProcessTask {
    let key: String
    let title: String
    let explanation: String
    let action: String
    let evidence: String
}
struct TaskTotal: Identifiable {
    let task: ProcessTask
    let count: Int
    let memory: Double
    let cpu: Double
    var id: String { task.key }
}
enum ProcessTasks {
    static func describe(_ p: ProcessReading) -> ProcessTask {
        let evidence = p.taskType.map { "进程类型：\($0)" } ?? "依据进程名称；未读到类型标记"
        func role(_ key: String, _ title: String, _ explanation: String, _ action: String) -> ProcessTask {
            ProcessTask(key: key, title: title, explanation: explanation, action: action, evidence: evidence)
        }
        switch p.taskType {
        case "app-main":
            return role("main", "主程序", "负责应用入口和子进程协调；不能从这里区分具体聊天、文档或操作。", "保留应用，先保存内容，再关闭一个已不用的额外窗口；通过应用内的任务列表检查具体操作。")
        case "renderer":
            return role("renderer", "页面与界面", "负责应用内页面的显示和脚本执行。一个进程不一定只对应一个窗口；当前无法识别具体文档或聊天名称。", "回到应用，关闭暂时不用的文档、网页或独立窗口，观察本进程及应用总占用是否回落。")
        case "gpu-process":
            return role("gpu", "图形与视频显示", "负责图形合成等工作；此处 CPU 是该进程的处理器占用，不是 GPU 使用率，也不能据此确认正在播放视频。", "可以先暂停视频、动画或屏幕共享，再观察占用。此进程可能服务多个页面。")
        case "utility":
            switch p.taskService {
            case "audio.mojom.AudioService":
                return role("audio", "音频服务", "提供音频输入或输出能力。进程存在不等于正在录音；是否使用麦克风要结合设备状态。", "检查应用的会议、通话、语音输入和麦克风选择；不用时从应用内结束对应功能。")
            case "video_capture.mojom.VideoCaptureService":
                return role("camera", "视频采集服务", "提供摄像头采集能力。服务存在不等于摄像头已打开，请结合摄像头状态核对。", "检查应用内的视频会议或摄像头预览，不用时从应用内关闭。")
            case "storage.mojom.StorageService":
                return role("storage", "应用存储服务", "处理应用内部存储访问；不能从该类型判断正在读写哪个文件。", "若持续读写较高，可在应用内暂停可稍后继续的文件操作，并观察磁盘等待。")
            case "network.mojom.NetworkService":
                return role("network", "网络服务", "处理应用网络请求；此页未采集流量，不能判断是哪次下载或请求。", "检查应用里的下载、上传或同步任务，优先暂停暂时不用的任务。")
            case "jash.mojom.JSRuntimeService":
                return role("script", "脚本运行服务", "类型标记表明这是脚本运行模块；尚不能识别具体业务任务。", "回到应用检查正在执行的操作；任务完成后观察 CPU 是否回落。")
            default:
                return role("utility", "辅助服务", "应用的辅助模块；目前无法可靠确定具体业务用途。", "结合占用变化排查应用内的活动；可先保存工作，再从应用内停止相关功能。")
            }
        case "monitor":
            return role("monitor", "应用监控辅助模块", "这是应用自身的 monitor 类型进程；具体业务用途未公开。", "通常由主程序管理，先处理应用内的工作，再观察是否仍持续占用。")
        case "backend":
            return role("backend", "应用后台模块", "类型为 backend；不能进一步确认是消息同步、索引还是其他后台工作。", "保留应用在线，先查看应用内正在同步、下载或执行的任务，只暂停一项不急的操作。")
        case "iron":
            return role("iron", "飞书辅助模块（Iron）", "这是飞书标记为 Iron 的辅助模块；具体业务任务未知。若查询到麦克风输入，会在下方单独显示。", "若它正在使用麦克风，请检查飞书的会议、通话或语音功能与输入设备设置。")
        default:
            if p.name.localizedCaseInsensitiveContains("Renderer") {
                return role("renderer", "页面与界面", "名称包含 Renderer，推测为界面渲染模块；具体页面未知。", "回到应用关闭不用的页面或窗口，再比较总占用。")
            }
            if let roleName = p.role {
                return role("named:\(roleName)", roleName, "这是根据进程名称识别的用途，具体业务任务未确认。", "在所属应用中检查对应操作，保存工作后再暂停。")
            }
            return role("unknown:\(p.taskType ?? p.name)", "用途待确认", "系统读数可确认资源占用，但目前没有足够信息确定此进程正在处理的具体任务。", "先定位所属应用和持续占用，再从应用内关闭不用的功能。")
        }
    }
    static func totals(_ readings: [ProcessReading]) -> [TaskTotal] {
        Dictionary(grouping: readings, by: { describe($0).key }).values.compactMap { group in
            guard let first = group.first else { return nil }
            return TaskTotal(task: describe(first), count: group.count, memory: group.map(\.memory).reduce(0,+),
                             cpu: group.compactMap(\.cpu).reduce(0,+))
        }.sorted { $0.memory == $1.memory ? $0.id < $1.id : $0.memory > $1.memory }
    }
    static func impact(_ p: ProcessReading, trace: [ProcessObservation]) -> String {
        var recent = [ProcessObservation]()
        for point in trace.reversed() {
            guard point.reading.birth == p.birth else { break }
            if let newer = recent.first, newer.date.timeIntervalSince(point.date) > 7 { break }
            recent.insert(point, at: 0)
        }
        let cpu = p.cpu.map { $0 < 1 ? String(format: "%.1f%%", $0) : percent($0) } ?? "未知"
        var text = "当前内存 \(size(p.memory))，CPU \(cpu)，读写 \(rate(p.value(.disk)))。"
        let duration = recent.last.flatMap { last in recent.first.map { last.date.timeIntervalSince($0.date) } } ?? 0
        let cpus = recent.compactMap { $0.reading.cpu }
        if duration >= 9, cpus.count >= 4 {
            let average = cpus.reduce(0,+) / Double(cpus.count)
            text += "最近约 \(Int(duration)) 秒平均 CPU \(percent(average))。"
            if average >= 30 && (p.cpu ?? 0) >= 25 { text += "持续计算较多，可能增加发热；是否导致卡顿还需结合全机压力。" }
            else if average < 5 { text += "这段时间计算负担较低，主要关注内存余量。" }
        } else { text += "正在积累连续样本，暂不判断是否持续忙碌。" }
        if duration >= 9, let first = recent.first {
            let growth = p.memory - first.reading.memory
            if abs(growth) >= 32 * miB { text += "期间内存\(growth > 0 ? "增加" : "减少")约 \(size(abs(growth)))；短期增长不能证明内存泄漏。" }
        }
        return text
    }
}
