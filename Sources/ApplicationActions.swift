import AppKit
import Combine

protocol QuitApplication: AnyObject {
    var bundleURL: URL? { get }
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: QuitApplication {}

final class ApplicationActions: ObservableObject {
    @Published private(set) var pendingIDs = Set<String>()
    @Published private(set) var message: String?

    private struct Pending {
        let application: any QuitApplication
        let name: String
        let requestedAt: Date
    }
    private var pending = [String: Pending]()
    private var timer: Timer?
    private let runningApplications: () -> [any QuitApplication]

    init(runningApplications: @escaping () -> [any QuitApplication] = { NSWorkspace.shared.runningApplications }) {
        self.runningApplications = runningApplications
    }

    func quit(_ load: Load, path: String?, fresh: Bool) {
        guard !pendingIDs.contains(load.id) else { return }
        guard fresh, load.isApplication == true, let path,
              path.hasSuffix(".app"), !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else {
            message = "这条应用信息已变化，请等采样刷新后重试。"
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url != Bundle.main.bundleURL.standardizedFileURL else {
            message = "可以从菜单栏退出 Mac 脉搏。"
            return
        }
        let matching = runningApplications().filter {
            !$0.isTerminated && $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == url
        }
        guard matching.count == 1, let app = matching.first else {
            message = matching.isEmpty ? "\(load.name) 已退出或正在刷新。"
                : "\(load.name) 有多个运行实例，请切到要退出的那个实例操作。"
            return
        }
        guard app.terminate() else {
            message = "退出请求未送达，请检查 \(load.name) 是否仍在运行。"
            return
        }
        pending[load.id] = Pending(application: app, name: load.name, requestedAt: Date())
        pendingIDs.insert(load.id)
        message = "正在退出 \(load.name)… 若出现保存提示，请在应用中处理。"
        checkPending()
        if !pending.isEmpty && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkPending()
            }
        }
    }

    func open(_ load: Load, path: String?, fresh: Bool) {
        guard fresh, load.isApplication == true, let path, path.hasSuffix(".app") else {
            message = "应用信息正在刷新，请稍后再打开。"; return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let matches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL == url
        }
        guard matches.count == 1, let app = matches.first else {
            message = "未能唯一定位这个运行实例，请从 Dock 切换到 \(load.name)。"; return
        }
        if !app.activate(options: [.activateAllWindows]) {
            message = "请从 Dock 切换到 \(load.name)，按建议调整一项。"
        }
    }

    func checkPending(now: Date = Date()) {
        for (id, request) in pending {
            if request.application.isTerminated {
                pending.removeValue(forKey: id)
                pendingIDs.remove(id)
                message = "\(request.name) 已退出，正在更新占用。"
            } else if now.timeIntervalSince(request.requestedAt) >= 20 {
                pending.removeValue(forKey: id)
                pendingIDs.remove(id)
                message = "\(request.name) 仍在运行，请查看它的保存或退出提示。"
            }
        }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }
}
