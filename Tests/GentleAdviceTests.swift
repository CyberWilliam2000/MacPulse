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
    precondition(advice.allSatisfy { !$0.expected.contains("比较效果") })
    sample.sources.append(Load(id: "self", name: "Mac 脉搏", memory: 20 * giB, isApplication: true))
    precondition(!Advice.applications([sample]).contains { $0.id == "self" })
    var stable = StableApplicationOrder()
    stable.reconcile(["one", "two"])
    stable.reconcile(["two", "one"])
    precondition(stable.ids == ["one", "two"], "Refresh must not swap force-close targets under the pointer.")
    stable.reconcile(["two", "three"])
    precondition(stable.ids == ["two", "three"])
    print("Advice/list checks passed (direct inspection, optional steps, microphone identity, stable row order).")
}
