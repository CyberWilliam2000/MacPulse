import Foundation

func verifyGentleAdvice() {
    var sample = DiagnosisTests.make(0, pressure: 2, swap: 10 * miB)
    sample.sources = [Load(id: "wx", name: "WeChat", memory: 2 * giB, isApplication: true),
                      Load(id: "gpt", name: "ChatGPT", memory: 3 * giB, isApplication: true)]
    let advice = Advice.suggestions([sample])
    precondition(advice.count == 2)
    for item in advice {
        precondition(!item.title.contains("退出") && !item.action.contains("⌘Q") && !item.action.contains("结束进程"))
        precondition(item.steps.count >= 2 && item.action.contains("保留"))
    }
    let wx = advice.first { $0.id == "wx" }!
    precondition(wx.action.contains("双开") && wx.action.contains("图片"))
    let gpt = advice.first { $0.id == "gpt" }!
    precondition(gpt.action.contains("无需") && gpt.action.contains("历史对话"))
    let process = ProcessReading(pid: 50, name: "Lark Helper (Iron)", application: "Lark", cpu: 20,
                                 memory: 700 * miB, read: 0, write: 0, taskType: "iron", birth: 42)
    sample.sources = [Load(id: "fs", name: "Lark", memory: 2 * giB, isApplication: true)]
    let hint = MicrophoneHint(pid: 50, birth: 42, device: "iPhone 麦克风")
    let matched = Advice.suggestions([sample], processes: ["fs": [process]], microphones: [hint])
    precondition(matched[0].action.contains("输入设备切回") && matched[0].evidence.contains("同一进程"))
    let reused = MicrophoneHint(pid: 50, birth: 41, device: "iPhone 麦克风")
    precondition(!Advice.suggestions([sample], processes: ["fs": [process]], microphones: [reused])[0].action.contains("输入设备切回"))
    let check = AdjustmentCheck()
    let start = sample.id
    check.begin(sample.sources[0], samples: [sample], now: start)
    precondition(check.current != nil)
    var period = [Sample]()
    for second in stride(from: 0, through: 30, by: 3) {
        var point = sample; point.id = start.addingTimeInterval(Double(second))
        point.sources[0].memory = giB
        period.append(point)
    }
    check.accept(period)
    precondition(check.current == nil && check.message?.contains("减少") == true && check.message?.contains("其他任务") == true)
    check.begin(sample.sources[0], samples: [sample], now: start)
    check.accept([sample, period.last!])
    precondition(check.message?.contains("中断") == true)
    check.begin(sample.sources[0], samples: [sample], now: start.addingTimeInterval(60))
    precondition(check.current == nil && check.message?.contains("最新采样") == true)
    print("Gentle advice checks passed (keep essential apps, concrete steps, microphone identity, before/after, gaps, stale samples).")
}
