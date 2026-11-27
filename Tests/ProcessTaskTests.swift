import Foundation

func verifyProcessTasks() {
    var renderer = ProcessReading(pid: 12, name: "Lark Helper (Renderer)", application: "Lark",
                                  cpu: 0.2, memory: 750 * miB, read: 0, write: 0,
                                  taskType: "renderer", rendererID: "445", parentPID: 1, birth: 42)
    precondition(ProcessTasks.describe(renderer).title == "页面与界面")
    precondition(ProcessTasks.describe(renderer).explanation.contains("无法识别具体文档"))
    var service = renderer; service.taskType = "utility"; service.taskService = "audio.mojom.AudioService"
    precondition(ProcessTasks.describe(service).title == "音频服务")
    precondition(ProcessTasks.describe(service).explanation.contains("不等于正在录音"))
    service.taskService = "video_capture.mojom.VideoCaptureService"
    precondition(ProcessTasks.describe(service).title == "视频采集服务")
    service.taskType = "undocumented-feature"
    precondition(ProcessTasks.describe(service).explanation.contains("推测"), "Name fallback must be marked as inference.")
    service = ProcessReading(pid: 13, name: "Lark Helper (Iron)", application: "Lark", cpu: 0, memory: 750 * miB,
                             read: 0, write: 0, taskType: "iron")
    precondition(ProcessTasks.describe(service).explanation.contains("具体"))
    let totals = ProcessTasks.totals([renderer, renderer, service])
    precondition(totals[0].count == 2 && totals[0].memory == 1500 * miB)
    let start = Date(timeIntervalSince1970: 1000)
    func trace(_ offsets: [Double], cpu: Double = 0.2, birth: UInt64 = 42) -> [ProcessObservation] {
        offsets.map { t in
            var reading = renderer
            reading = ProcessReading(pid: reading.pid, name: reading.name, application: reading.application,
                                     cpu: cpu, memory: reading.memory, read: 0, write: 0, birth: birth)
            return ProcessObservation(date: start.addingTimeInterval(t), reading: reading)
        }
    }
    precondition(ProcessTasks.impact(renderer, trace: trace([0,3,6,9])).contains("计算负担较低"))
    renderer = ProcessReading(pid: 12, name: "Lark Helper", application: "Lark", cpu: 90,
                              memory: 800 * miB, read: 0, write: 0, birth: 42)
    precondition(ProcessTasks.impact(renderer, trace: trace([0,3,6,9], cpu: 90)).contains("持续计算较多"))
    precondition(!ProcessTasks.impact(renderer, trace: trace([0,3,6,30], cpu: 90)).contains("持续计算较多"))
    precondition(!ProcessTasks.impact(renderer, trace: trace([0,3,6,9], cpu: 90, birth: 41)).contains("持续计算较多"))
    let legacy = "{\"pid\":12,\"name\":\"Feishu\",\"application\":\"Lark\",\"cpu\":0,\"memory\":1,\"read\":0,\"write\":0}"
    let old = try! JSONDecoder().decode(ProcessReading.self, from: Data(legacy.utf8))
    precondition(old.birth == nil && old.taskType == nil)
    print("Task explanations passed (modules, unknown pages, sustained CPU, gaps, PID reuse, legacy records).")
}
