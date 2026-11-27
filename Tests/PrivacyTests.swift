import Foundation

@main struct PrivacyTests {
    static func main() throws {
        let use = DeviceUse(id: "mic:10:123:7", kind: .microphone, application: "Test App", process: "Test Helper",
                            pid: 10, device: "iPhone 麦克风")
        func sample(_ seconds: Double, _ uses: [DeviceUse], audioOK: Bool = true) -> PrivacyReading {
            PrivacyReading(date: Date(timeIntervalSince1970: 1_000_000 + seconds), uses: uses,
                           audioOK: audioOK, cameraOK: true)
        }
        var history = PrivacyHistory()
        history.consume(sample(0, [use])); history.consume(sample(2, [use]))
        precondition(history.records.count == 1 && history.records[0].lastSeen == sample(2, []).date)
        history.consume(sample(4, []))
        precondition(history.records[0].finish == "后续采样未再检测到" && history.active.isEmpty)
        history.consume(sample(6, [use]))
        precondition(history.records.count == 2)
        history.consume(sample(8, [], audioOK: false))
        precondition(history.records[0].finish == "读取中断，结束时间未知")
        history.consume(sample(10, [use]))
        history.consume(sample(12, [use], audioOK: false))
        precondition(history.records.count == 3 && history.records[0].finish == nil,
                     "A partial list still positively identifies known active users.")
        history.consume(sample(30, [use]))
        precondition(history.records.count == 4 && history.records[1].finish == "监测中断，结束时间未知")
        var changed = use; changed.id = "mic:10:123:8"; changed.device = "Mac 麦克风"
        history.consume(sample(32, [changed]))
        precondition(history.records[0].use.device == "Mac 麦克风" && history.records[1].finish != nil)
        let data = try JSONEncoder().encode(history.records)
        var restored = PrivacyHistory()
        restored.restore(try JSONDecoder().decode([PrivacyRecord].self, from: data))
        precondition(restored.active.isEmpty && restored.records[0].finish?.contains("上次监测") == true)
        restored.consume(sample(34, [changed]))
        precondition(restored.records.count == history.records.count + 1)
        restored.consume(sample(30 * 86400 + 100, []))
        precondition(restored.records.isEmpty, "Retention is bounded by last observed time.")
        var bounded = PrivacyHistory()
        for n in 0..<510 {
            var item = use; item.id = "use\(n)"
            bounded.consume(sample(Double(n * 2), [item]))
        }
        precondition(bounded.records.count == 500 && bounded.active.count == 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PulsePrivacyTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("history.json")
        let monitor = PrivacyMonitor(storage: storage)
        monitor.accept(sample(0, [use])); monitor.accept(sample(2, []))
        let reopened = PrivacyMonitor(storage: storage)
        precondition(reopened.history.records.count == 1 && reopened.history.records[0].finish != nil)
        print("Privacy checks passed (attribution, transitions, gaps, partial reads, retention, restart, storage).")
    }
}
