import Foundation
import Combine

struct AdjustmentBaseline {
    let app: Load
    let started: Date
    let before: Sample
}
final class AdjustmentCheck: ObservableObject {
    @Published private(set) var current: AdjustmentBaseline?
    @Published private(set) var message: String?
    func begin(_ app: Load, samples: [Sample], now: Date = Date()) {
        guard let latest = samples.last, now.timeIntervalSince(latest.id) >= 0, now.timeIntervalSince(latest.id) < 8,
              let live = latest.sources.first(where: { $0.id == app.id }) else {
            message = "先等最新采样，再开始比较。"; return
        }
        current = AdjustmentBaseline(app: live, started: latest.id, before: latest)
        message = "已记录 \(live.name) 的调整前读数。现在只做一项小调整，约 30 秒后查看变化。"
    }
    func accept(_ samples: [Sample]) {
        guard let baseline = current, let last = samples.last else { return }
        let period = samples.filter { $0.id >= baseline.started }
        let gaps = (period.first.map { $0.id.timeIntervalSince(baseline.started) > 8 } ?? true) ||
            zip(period, period.dropFirst()).contains { $1.id.timeIntervalSince($0.id) > 8 }
        if gaps {
            current = nil; message = "比较期间采样中断，暂时无法判断这次调整的变化。"; return
        }
        guard last.id.timeIntervalSince(baseline.started) >= 30 else { return }
        current = nil
        guard let after = last.sources.first(where: { $0.id == baseline.app.id }) else {
            message = "比较结束，\(baseline.app.name) 已不在采样榜中，无法确认应用占用变化。请结合全机内存压力和体感判断。"; return
        }
        let delta = after.memory - baseline.app.memory
        let change = abs(delta) < miB ? "基本不变" : (delta < 0 ? "减少 " : "增加 ") + size(abs(delta))
        message = "\(after.name) · 约 30 秒比较\n内存 \(size(baseline.app.memory)) → \(size(after.memory))（\(change)）\n" +
            "CPU \(percent(baseline.app.cpu)) → \(percent(after.cpu))；全机交换 \(rate(baseline.before.swapTotal)) → \(rate(last.swapTotal))\n" +
            "内存压力\(baseline.before.pressureLabel) → \(last.pressureLabel)；热压力\(baseline.before.thermalLabel) → \(last.thermalLabel)。\n" +
            "这是前后观测对比，CPU 为采样瞬时值，不能排除其他任务的影响；请同时判断操作是否更流畅。"
    }
}
