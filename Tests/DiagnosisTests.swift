import Foundation

@main struct DiagnosisTests {
    static func make(_ offset: TimeInterval, cpu: Double? = 24, pressure: Int? = 1,
                     swap: Double = 0, thermal: Int = 0, temperature: Double? = 55,
                     io: Double = 0, ops: Double = 0, ms: Double? = nil) -> Sample {
        Sample(id: Date(timeIntervalSince1970: 2000 + offset), cpu: cpu, pressure: pressure,
               swapUsed: 5 * giB, swapRead: 0, swapWrite: swap, compressed: 4 * giB,
               diskRead: io, diskWrite: 0, diskOps: ops, diskMS: ms,
               free: 50 * giB, capacity: 250 * giB, thermal: thermal, temperature: temperature,
               sensorCount: temperature == nil ? 0 : 1,
               sources: [Load(id: "1", name: "Test Browser", cpu: 120, memory: 2 * giB, read: io / 2)],
               listed: 50, readable: 35)
    }

    static func main() {
        verifyApplicationActions()
        verifyProcessTasks()
        verifyGentleAdvice()
        let healthy = [make(0), make(3), make(6)]
        precondition(Diagnosis.findings(healthy).isEmpty, "Old swap alone is not a bottleneck.")
        precondition(Diagnosis.ask("先查什么？", samples: healthy, label: "实时").contains("不能确定"))
        precondition(Diagnosis.ask("显卡是不是原因？", samples: healthy, label: "实时").contains("没有采集 GPU"))
        let hot = [make(0, cpu: 91), make(3, cpu: 95), make(6, cpu: 68, thermal: 2, temperature: nil)]
        let signal = Diagnosis.findings(hot)
        precondition(signal.first?.metric == .heat && signal[0].evidence.contains("出现前"))
        precondition(Diagnosis.timeline(hot).map(\.metric) == [.cpu, .heat])
        precondition(Diagnosis.ask("是不是发热？", samples: hot, label: "记录").contains("没有读到摄氏温度"))
        precondition(Diagnosis.findings([make(0, thermal: 1, temperature: 92)]).first?.level == 15)
        let ioOnly = [make(0, io: 300 * miB, ops: 200, ms: 0.4), make(3, io: 300 * miB, ops: 220, ms: 0.5)]
        precondition(Diagnosis.findings(ioOnly).first?.level == 18, "Throughput is not a bottleneck by itself.")
        let memoryIO = [0.0, 3.0, 6.0].map { make($0, pressure: 2, swap: 30 * miB, io: 50 * miB, ops: 90, ms: 12) }
        precondition(Diagnosis.findings(memoryIO).first?.metric == .memory)
        precondition(Diagnosis.findings(memoryIO).first { $0.metric == .disk }?.evidence.contains("内存交换") == true)
        let gapped = [make(0, cpu: 98), make(30, cpu: 98)]
        precondition(Diagnosis.findings(gapped).first?.level == 20, "A sampling gap cannot prove a sustained spike.")
        let missing = [make(0, cpu: nil, pressure: nil, temperature: nil)]
        precondition(Diagnosis.ask("内存是不是原因", samples: missing, label: "实时").contains("压力不可用"))
        precondition(Diagnosis.currentPressure(healthy).isEmpty)
        precondition(Diagnosis.currentPressure([make(0, pressure: 2)]) == [.memory])
        precondition(Diagnosis.currentPressure([make(0, thermal: 2)]) == [.heat])
        precondition(Diagnosis.currentPressure([make(0, thermal: 1, temperature: 90)]).isEmpty)
        precondition(Diagnosis.currentPressure([make(0, cpu: 91), make(3, cpu: 95)]) == [.cpu])
        precondition(Diagnosis.currentPressure([make(0, cpu: 91), make(3)]).isEmpty)
        precondition(Diagnosis.currentPressure(gapped).isEmpty)
        precondition(Diagnosis.currentPressure(ioOnly).isEmpty)
        let slowDisk = [make(0, ops: 90, ms: 12), make(3, ops: 90, ms: 12)]
        precondition(Diagnosis.currentPressure(slowDisk) == [.disk])
        precondition(Diagnosis.currentPressure([make(0, swap: 30 * miB), make(3, swap: 30 * miB)]) == [.memory])
        let compiler = ProcessReading(pid: 211, name: "swift-frontend", application: "ChatGPT",
                                      cpu: 95, memory: 150 * miB, read: 0, write: 0)
        var peak = make(3, cpu: 95)
        peak.processes = [compiler]
        var settled = make(6, cpu: 25)
        settled.processes = []
        let period = [make(0, cpu: 91), peak, settled]
        precondition(Diagnosis.processEvidence(.cpu, in: period)?.sample.id == peak.id)
        precondition(Diagnosis.processEvidence(.cpu, in: [settled])?.duringPressure == false)
        precondition(Diagnosis.ask("刚才是哪个任务卡顿？", samples: period, label: "记录").contains("PID 211"))
        let historical = Incident(id: Date(), samples: period)
        let restored = try! JSONDecoder().decode(Incident.self, from: JSONEncoder().encode(historical))
        precondition(restored.samples[0].processes == nil && restored.samples[1].processes?.first?.name == "swift-frontend")
        let snapshot = Incident(id: Date(), samples: memoryIO)
        var memoryBusy = make(6, pressure: 2, swap: 15 * miB)
        memoryBusy.sources = [
            Load(id: "chat", name: "ChatGPT", cpu: 80, memory: 4 * giB, members: 20, isApplication: true),
            Load(id: "browser", name: "Google Chrome", memory: 2 * giB, members: 15, isApplication: true),
            Load(id: "system", name: "kernel_task", memory: 8 * giB, isApplication: false),
            Load(id: "self", name: "Mac 脉搏", memory: giB, isApplication: true)
        ]
        memoryBusy.processes = [compiler]
        let memoryAdvice = Advice.suggestions([memoryBusy], focus: .memory)
        precondition(memoryAdvice.map(\.application.name) == ["ChatGPT", "Google Chrome"])
        var largeApps = memoryBusy
        largeApps.sources = [
            Load(id: "a", name: "App A", memory: 8 * giB, isApplication: true),
            Load(id: "b", name: "App B", memory: 9 * giB, isApplication: true)
        ]
        precondition(Advice.suggestions([largeApps], focus: .memory).first?.application.id == "b")
        precondition(memoryAdvice.first?.action.contains("保留当前对话") == true)
        precondition(Diagnosis.ask("内存优化建议，关哪个？", samples: [memoryBusy], label: "实时").contains("Google Chrome"))
        var previousBusy = memoryBusy
        previousBusy.id = memoryBusy.id.addingTimeInterval(-3)
        let warmAdvice = Advice.suggestions([previousBusy, memoryBusy], focus: .heat)
        precondition(warmAdvice.first?.metric == .cpu && warmAdvice.first?.evidence.contains("PID 211") == true)
        precondition(Advice.suggestions([memoryBusy], focus: .heat).isEmpty, "One sample cannot prove sustained CPU load.")
        var recovered = memoryBusy
        recovered.sources = []
        precondition(Advice.suggestions([memoryBusy, recovered]).isEmpty, "An exited task must disappear from advice.")
        var legacy = memoryBusy
        legacy.sources[0].isApplication = nil
        precondition(!Advice.suggestions([legacy]).contains { $0.application.id == "chat" })
        let copy = try! JSONDecoder().decode(Incident.self, from: JSONEncoder().encode(snapshot))
        precondition(copy.samples.count == 3 && copy.samples.last?.pressure == 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPulse-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("incidents.json")
        let monitor = Monitor(storage: storage)
        precondition(!monitor.mark())
        monitor.start()
        let deadline = Date().addingTimeInterval(3)
        while monitor.samples.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(monitor.mark(), "A real sample can be marked and saved.")
        let reopened = Monitor(storage: storage)
        precondition(reopened.incidents.count == 1 && reopened.incidents[0].samples.first?.processes != nil)
        precondition(reopened.remove(reopened.incidents[0].id))
        precondition(Monitor(storage: storage).incidents.isEmpty)
        print("Diagnosis checks passed (thermal, memory, disk, gaps, missing metrics and snapshot round-trip).")
    }
}
