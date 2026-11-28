import AppKit
import Combine

protocol QuitApplication: AnyObject {
    var bundleURL: URL? { get }
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
    func forceTerminate() -> Bool
}

extension NSRunningApplication: QuitApplication {}

final class ApplicationActions: ObservableObject {
    @Published private(set) var pendingIDs = Set<String>()
    @Published private(set) var message: String?

    private struct Pending {
        let application: any QuitApplication
        let name: String
        let requestedAt: Date
        let force: Bool
    }
    private var pending = [String: Pending]()
    private var timer: Timer?
    private let runningApplications: () -> [any QuitApplication]
    private let processBirth: (pid_t) -> UInt64

    init(runningApplications: @escaping () -> [any QuitApplication] = { NSWorkspace.shared.runningApplications },
         processBirth: @escaping (pid_t) -> UInt64 = { pulse_process_birth($0) }) {
        self.runningApplications = runningApplications
        self.processBirth = processBirth
    }

    func quit(_ load: Load, path: String?, fresh: Bool) {
        request(load, path: path, fresh: fresh, force: false)
    }

    func forceQuit(_ load: Load, path: String?, fresh: Bool) {
        request(load, path: path, fresh: fresh, force: true)
    }

    private func request(_ load: Load, path: String?, fresh: Bool, force: Bool) {
        guard !pendingIDs.contains(load.id) else { return }
        guard fresh, load.isApplication == true, let path,
              path.hasSuffix(".app"), !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else {
            message = "这条应用信息已变化，请等采样刷新后重试。"
            return
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard !url.path.hasPrefix("/System/"), !url.path.hasPrefix("/usr/") else {
            message = "系统组件不能从这里关闭。"; return
        }
        guard url != Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL else {
            message = "可以从菜单栏退出 Mac 脉搏。"
            return
        }
        let matching = runningApplications().filter {
            !$0.isTerminated && $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
        }
        guard matching.count == 1, let app = matching.first else {
            message = matching.isEmpty ? "\(load.name) 已退出或正在刷新。"
                : "\(load.name) 有多个运行实例，请切到要退出的那个实例操作。"
            return
        }
        if force {
            guard let pid = load.applicationPID, let birth = load.applicationBirth, birth != 0,
                  app.processIdentifier == pid, processBirth(pid) == birth, !app.isTerminated else {
                message = "应用已重启或身份信息不完整，请等下一次采样后重试。"; return
            }
        }
        guard force ? app.forceTerminate() : app.terminate() else {
            message = force ? "强制关闭请求未送达，请检查 \(load.name) 是否仍在运行。" : "退出请求未送达，请检查 \(load.name) 是否仍在运行。"
            return
        }
        pending[load.id] = Pending(application: app, name: load.name, requestedAt: Date(), force: force)
        pendingIDs.insert(load.id)
        message = force ? "正在强制关闭 \(load.name)…" : "正在退出 \(load.name)… 若出现保存提示，请在应用中处理。"
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
                message = request.force ? "\(request.name) 已关闭，正在刷新占用。" : "\(request.name) 已退出，正在更新占用。"
            } else if now.timeIntervalSince(request.requestedAt) >= (request.force ? 8 : 20) {
                pending.removeValue(forKey: id)
                pendingIDs.remove(id)
                message = request.force ? "\(request.name) 仍在运行，强制关闭未完成；请从系统核对。" : "\(request.name) 仍在运行，请查看它的保存或退出提示。"
            }
        }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }
}
