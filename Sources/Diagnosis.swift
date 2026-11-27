import Foundation

struct Finding: Identifiable {
    var metric: Metric
    var title: String
    var evidence: String
    var action: String
    var level: Int
    var id: Metric { metric }
}

enum Diagnosis {
    private static func highCPU(_ sample: Sample) -> Bool { (sample.cpu ?? 0) >= 85 }
    private static func activeSwap(_ sample: Sample) -> Bool { (sample.swapTotal ?? 0) >= 8 * miB }
    private static func slowDisk(_ sample: Sample) -> Bool {
        (sample.diskOps ?? 0) >= 30 && (sample.diskMS ?? 0) >= 8
    }
    private static func adjacent(_ first: Sample, _ second: Sample) -> Bool {
        let interval = second.id.timeIntervalSince(first.id)
        return interval > 0 && interval <= 7
    }

    static func currentPressure(_ samples: [Sample]) -> [Metric] {
        guard let latest = samples.last else { return [] }
        let previous = samples.dropLast().last.flatMap { adjacent($0, latest) ? $0 : nil }
        func continuing(_ check: (Sample) -> Bool) -> Bool {
            check(latest) && previous.map(check) == true
        }
        var metrics = [Metric]()
        if continuing(highCPU) { metrics.append(.cpu) }
        if (latest.pressure ?? 0) >= 2 || continuing(activeSwap) { metrics.append(.memory) }
        if latest.thermal == 2 || latest.thermal == 3 { metrics.append(.heat) }
        if continuing(slowDisk) { metrics.append(.disk) }
        return metrics
    }

    static func findings(_ samples: [Sample]) -> [Finding] {
        guard let last = samples.last else { return [] }
        let recent = samples.filter { last.id.timeIntervalSince($0.id) <= 45 }
        func sustained(_ predicate: (Sample) -> Bool) -> Bool {
            zip(recent, recent.dropFirst()).contains {
                adjacent($0, $1) && predicate($0) && predicate($1)
            }
        }
        func app(_ metric: Metric, _ relevant: [Sample]) -> String? {
            let leaders = relevant.compactMap { $0.ranking(metric).first }
            let grouped = Dictionary(grouping: leaders, by: \.name)
            return grouped.max {
                if $0.value.count != $1.value.count { return $0.value.count < $1.value.count }
                return ($0.value.map { $0.value(metric) }.max() ?? 0) < ($1.value.map { $0.value(metric) }.max() ?? 0)
            }?.key
        }
        var result = [Finding]()
        let hot = recent.filter { $0.thermal >= 2 }
        if let first = hot.first {
            let peak = hot.map(\.thermal).max() ?? 2
            let pressureBeginning = recent.count > 1 && first.id > recent[0].id
            let highBeforeHeat = pressureBeginning && recent.contains { $0.id < first.id && ($0.cpu ?? 0) >= 85 }
            let timing = highBeforeHeat ? "，较高热压力出现前录到过 CPU 高负载" : ""
            let cpu = app(.cpu, hot).map { "同期可见 CPU 榜首常见 \($0)，可先检查它是否在运行重任务。" } ?? ""
            result.append(Finding(metric: .heat, title: peak >= 3 ? "热压力严重，系统性能受影响" : "热压力较高，可能拖慢电脑", evidence: "\(clockLabel(first.id)) 已记录到较高热压力\(timing)。\(cpu)", action: "先把电脑放到平整硬桌面，暂停导出、编译等重任务，观察热压力回落后卡顿有没有改善。", level: peak >= 3 ? 100 : 85))
        } else if recent.contains(where: { $0.thermal == 1 }) {
            result.append(Finding(metric: .heat, title: "热压力曾升高", evidence: "最近 45 秒没有录到较高或严重等级。机内温度升高本身不能证明系统限速。", action: "卡顿时再标记一次，对照热压力与 CPU、内存的变化。", level: 15))
        }

        let memory = recent.filter { ($0.pressure ?? 0) >= 2 }
        if !memory.isEmpty {
            let peakSwap = memory.compactMap(\.swapTotal).max()
            let leader = app(.memory, memory).map { "可读进程里，\($0) 的内存占用靠前。" } ?? ""
            let state = memory.contains { $0.pressure == 4 } ? "高" : "升高"
            result.append(Finding(metric: .memory, title: "内存压力\(state)", evidence: "最近 45 秒有 \(memory.count) 次采样录到内存压力，期间交换读写峰值 \(rate(peakSwap))。\(leader)", action: "保留常用软件，先保存内容，再关闭一个闲置预览、额外窗口或不用的重网页。一次只调整一项，比较内存压力和交换流量。", level: memory.contains { $0.pressure == 4 } || sustained { ($0.pressure ?? 0) >= 2 } ? 90 : 60))
        } else if sustained(activeSwap) {
            result.append(Finding(metric: .memory, title: "系统正在持续交换内存", evidence: "连续采样到较多交换读写。单看已用交换空间不能判断卡顿；这里看的是实际读写。", action: "先暂停切换大型应用，再关掉不需要的大标签组，比较交换速率和响应。", level: 65))
        }

        if sustained(highCPU) {
            let busy = recent.filter(highCPU)
            let lead = app(.cpu, busy).map { "，可见榜首常见 \($0)" } ?? ""
            result.append(Finding(metric: .cpu, title: "CPU 持续繁忙", evidence: "最近 45 秒至少两次连续采样达到全机 85% 以上\(lead)。", action: "先暂停榜首应用里能稍后继续的任务，例如导出、编译或同步，再观察响应。", level: 78))
        } else if let peak = recent.compactMap(\.cpu).max(), peak >= 85 {
            result.append(Finding(metric: .cpu, title: "CPU 有一次高峰", evidence: "最近 45 秒峰值 \(percent(peak))；没有录到连续高占用。", action: "如果卡顿反复出现，及时标记并核对榜首应用是否重复出现。", level: 20))
        }

        let swapping = recent.contains { activeSwap($0) && ($0.diskTotal ?? 0) > 0 }
        let busyDisk = recent.filter(slowDisk)
        if sustained(slowDisk) {
            let diskLeader = app(.disk, busyDisk).map { "同期可归属读写靠前的是 \($0)。" } ?? ""
            let caveat = swapping ? "同期还有内存交换，可能贡献了部分读写。" : ""
            result.append(Finding(metric: .disk, title: "磁盘读写可能在等待", evidence: "连续采样到较多 I/O，驱动计数的平均每次 I/O 用时偏长。\(diskLeader)\(caveat)", action: "检查是否在复制、下载或同步大文件；暂停一个任务，看看卡顿是否缓解。\(swapping ? "同时观察内存交换。" : "")", level: swapping ? 46 : 73))
        } else if let peak = recent.compactMap(\.diskTotal).max(), peak >= 40 * miB {
            result.append(Finding(metric: .disk, title: "有明显磁盘读写", evidence: "读写峰值 \(rate(peak))。单凭吞吐量不能判定磁盘拖慢了电脑。", action: "打开磁盘榜查看同期应用，再与内存交换和 I/O 用时对照。", level: 18))
        }
        if let free = last.free, let capacity = last.capacity, free < 15 * giB && free < capacity * 0.08,
           !result.contains(where: { $0.metric == .disk }) {
            result.append(Finding(metric: .disk, title: "启动盘可用空间较少", evidence: "还可用 \(size(free))，空间不足可能影响交换和大文件工作，无法单凭这项数据归因。", action: "到「系统设置 → 通用 → 储存空间」找可移动的大文件，保留手头需要的内容。", level: 36))
        }
        return result.sorted { $0.level > $1.level }
    }

    struct Signal: Identifiable {
        var metric: Metric
        var date: Date
        var label: String
        var id: Metric { metric }
    }

    static func timeline(_ samples: [Sample]) -> [Signal] {
        let candidates: [(Metric, String, (Sample) -> Bool)] = [
            (.cpu, "录到全机 CPU ≥ 85%", highCPU),
            (.memory, "录到内存压力", { ($0.pressure ?? 0) >= 2 }),
            (.disk, "录到较多 I/O 且用时偏长", slowDisk),
            (.heat, "录到较高或严重热压力", { $0.thermal >= 2 })
        ]
        return candidates.compactMap { metric, label, condition in
            samples.first(where: condition).map { Signal(metric: metric, date: $0.id, label: label) }
        }.sorted { $0.date == $1.date ? $0.metric.rawValue < $1.metric.rawValue : $0.date < $1.date }
    }

    static func processEvidence(_ metric: Metric, in samples: [Sample]) -> (sample: Sample, duringPressure: Bool)? {
        guard let last = samples.last else { return nil }
        let recent = samples.filter { last.id.timeIntervalSince($0.id) <= 45 }

        func score(_ sample: Sample) -> (Int, Double)? {
            switch metric {
            case .cpu: return highCPU(sample) ? (1, sample.cpu ?? 0) : nil
            case .memory:
                let level = sample.pressure ?? 0
                return level >= 2 || activeSwap(sample) ? (level >= 2 ? level : 1, sample.swapTotal ?? 0) : nil
            case .heat: return sample.thermal >= 2 ? (sample.thermal, sample.cpu ?? 0) : nil
            case .disk: return slowDisk(sample) ? (1, sample.diskMS ?? 0) : nil
            }
        }

        let strongest = recent.compactMap { sample in score(sample).map { (sample, $0) } }.max {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id < $1.0.id
        }
        return strongest.map { ($0.0, true) } ?? (last, false)
    }

    static func processNotes(_ metric: Metric, in samples: [Sample]) -> String? {
        guard let evidence = processEvidence(metric, in: samples),
              let readings = evidence.sample.processes else { return nil }
        let leaders = readings.ranked(for: metric).filter { ($0.value(metric) ?? 0) > 0 }.prefix(3)
        guard !leaders.isEmpty else { return nil }
        let lines = leaders.map { reading in
            let app = reading.application == reading.name ? "" : "（\(reading.application)）"
            let role = reading.role.map { " · \($0)" } ?? ""
            return "\(reading.name)\(app) · PID \(reading.pid) · \(reading.display(metric))\(role)"
        }
        let type = metric == .heat ? "CPU" : metric.title
        let event = evidence.duringPressure ? "压力出现时" : "最近采样"
        return "\(event)（\(clockLabel(evidence.sample.id))）的 \(type) 进程榜\n" + lines.joined(separator: "\n")
    }

    static func detail(_ metric: Metric, _ s: Sample) -> String {
        switch metric {
        case .cpu:
            let lead = s.ranking(.cpu).first.map { "可见应用或进程中，\($0.name) 为 \(percent($0.cpu))（100% 相当于一个逻辑核心）。" } ?? "暂时没有可归属的 CPU 读数。"
            return "全机 CPU \(percent(s.cpu))。\(lead) 全机占用不高时，单个应用仍可能卡在一个核心，或在等待其他资源。"
        case .memory:
            let lead = s.ranking(.memory).first.map { "可见占用榜首是 \($0.name)，约 \(size($0.memory))。" } ?? ""
            return "内存压力：\(s.pressureLabel)。已用交换 \(size(s.swapUsed))，交换读写 \(rate(s.swapTotal))，压缩内存 \(size(s.compressed))。\(lead) 要判断是不是内存拖慢，优先看压力和正在发生的交换。"
        case .disk:
            let lead = s.ranking(.disk).first.map { "可归属读写榜首：\($0.name)，约 \(rate($0.read + $0.write))。" } ?? "这一采样没有归属于可见进程的磁盘读写。"
            return "全机磁盘读 \(rate(s.diskRead))、写 \(rate(s.diskWrite))，启动盘还可用 \(size(s.free))。\(lead) 系统、文件缓存与交换的 I/O 不一定能归到应用。"
        case .heat:
            let probe = s.temperature.map { "内部传感器最高读数 \(degrees($0))（\(s.sensor ?? "PMU")，本次读到 \(s.sensorCount) 个探头）。" } ?? "当前没有读到摄氏温度，仍可看 macOS 的热压力。"
            return "\(probe) 热压力：\(s.thermalLabel)。传感器不测外壳温度；要判断性能是否受热影响，优先看热压力等级。"
        }
    }

    static func ask(_ input: String, samples: [Sample], label: String) -> String {
        guard let last = samples.last else { return "刚开始采样，请等几秒再问。卡顿发生时也可以点「刚刚卡了」。" }
        let q = input.lowercased()
        func contains(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        let findings = findings(samples)
        let header = "\(label) · \(clockLabel(last.id))"
        var requested = [Metric]()
        if contains(["温度", "热", "降频", "风扇", "temperature", "thermal"]) { requested.append(.heat) }
        if contains(["内存", "ram", "交换", "swap", "memory"]) { requested.append(.memory) }
        if contains(["磁盘", "硬盘", "ssd", "储存", "存储", "读写", "disk"]) { requested.append(.disk) }
        if contains(["cpu", "处理器", "核心"]) { requested.append(.cpu) }
        let wantsGPU = contains(["gpu", "显卡", "图形"])
        if contains(["优化", "建议", "关掉", "关闭", "暂停", "腾出", "腾内存"]) {
            let focus: Metric? = requested.count == 1 ? requested.first : nil
            return header + "\n\n" + Advice.text(samples, focus: focus)
        }
        if requested.isEmpty && wantsGPU {
            return "\(header)\n\n这个版本没有采集 GPU 占用，无法判断 GPU 是否导致卡顿。可以打开「活动监视器 → 窗口 → GPU 历史记录」核对。"
        }
        if !requested.isEmpty {
            var answers = requested.map { metric in
                let finding = findings.first { $0.metric == metric }
                let fallback: String
                switch metric {
                case .heat: fallback = "最近没有录到热压力升高。下次觉得又热又卡时立即标记，对照此前的热压力。"
                case .memory: fallback = last.pressure == nil ? "当前内存压力不可用，无法排除内存瓶颈。" : "这一段没有录到持续交换或明显内存压力。"
                case .disk: fallback = "这一段没有录到持续的磁盘等待信号。"
                case .cpu: fallback = "这一段没有录到持续的全机 CPU 高占用。"
                }
                let summary = "\(metric.title)｜\(detail(metric, last))\n" + (finding.map { "\($0.evidence)\n建议：\($0.action)" } ?? fallback)
                return [summary, processNotes(metric, in: samples)].compactMap { $0 }.joined(separator: "\n\n")
            }
            if wantsGPU { answers.append("本版没有采集 GPU 数据。") }
            return header + "\n\n" + answers.joined(separator: "\n\n")
        }
        let relevant = findings.filter { $0.level >= 45 }
        if let first = relevant.first {
            let also = relevant.dropFirst().prefix(2).map { "\($0.title)：\($0.evidence)" }.joined(separator: "\n")
            let processes = processNotes(first.metric, in: samples).map { "\n\n" + $0 } ?? ""
            return "\(header)\n\n先查：\(first.title)\n\(first.evidence)\(processes)\n\n可以先做：\(first.action)" + (also.isEmpty ? "" : "\n\n同时看到：\n" + also)
        }
        let brief = "CPU \(percent(last.cpu))，内存压力\(last.pressureLabel)，磁盘读写 \(rate(last.diskTotal))，热压力\(last.thermalLabel)。"
        if contains(["卡", "慢", "进程", "占用", "优化", "关闭", "关掉", "先查", "建议", "看看", "怎么", "谁", "原因", "为什么", "lag", "slow"]) {
            let note = findings.prefix(2).map { $0.title }.joined(separator: "、")
            let processes = contains(["进程", "哪个任务", "哪些任务", "谁在"]) ? processNotes(.cpu, in: samples) : nil
            return "\(header)\n\n当前这段数据还不能确定卡顿原因。\(brief)" + (note.isEmpty ? "" : "录到：\(note)。") +
                (processes.map { "\n\n" + $0 } ?? "") + "\n\n下次刚卡完时点「刚刚卡了」。如果只有某个应用卡，先对照该应用的 CPU、内存或磁盘榜。"
        }
        return "我可以按采样回答 CPU、内存、磁盘和发热问题。试试「刚才卡顿是为什么」「谁占内存最多」「发热拖慢了吗」。"
    }

    static func report(_ samples: [Sample], label: String) -> String {
        guard let last = samples.last else { return "还没有样本。" }
        let first = samples.first ?? last
        let ordered = findings(samples).map { finding in
            let note = processNotes(finding.metric, in: samples).map { "\n" + $0 } ?? ""
            return "• \(finding.title)：\(finding.evidence) 建议：\(finding.action)\(note)"
        }
        let advice = Advice.text(samples)
        let sampleCount = "采样：\(clockLabel(first.id))–\(clockLabel(last.id))，\(samples.count) 点；进程计数可读 \(last.readable)/\(last.listed)。"
        return (["Mac 脉搏 · \(label)", sampleCount, advice] + Metric.allCases.map { detail($0, last) } +
                (ordered.isEmpty ? ["没有足够证据确定主因。"] : ordered)).joined(separator: "\n")
    }
}
