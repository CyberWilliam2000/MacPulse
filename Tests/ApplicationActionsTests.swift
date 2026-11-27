import AppKit

private final class TestQuitApplication: QuitApplication {
    var bundleURL: URL?
    var processIdentifier: pid_t
    var isTerminated = false
    var acceptsQuit = true
    var requests = 0

    init(path: String, pid: pid_t) {
        bundleURL = URL(fileURLWithPath: path)
        processIdentifier = pid
    }

    func terminate() -> Bool {
        requests += 1
        return acceptsQuit
    }
}

func verifyApplicationActions() {
    let old = TestQuitApplication(path: "/Applications/WeChat 3.8.10.app", pid: 301)
    let current = TestQuitApplication(path: "/Applications/WeChat.app", pid: 302)
    let actions = ApplicationActions(runningApplications: { [old, current] })
    let load = Load(id: "old", name: "WeChat 3.8.10", memory: giB, isApplication: true)

    actions.quit(load, path: "/Applications/WeChat 3.8.10.app", fresh: true)
    precondition(old.requests == 1 && current.requests == 0, "Match the exact bundle, including versioned copies.")
    precondition(actions.pendingIDs.contains("old"))
    precondition(actions.message?.contains("已退出") == false, "Accepted quit does not prove termination.")
    actions.quit(load, path: "/Applications/WeChat 3.8.10.app", fresh: true)
    precondition(old.requests == 1, "Repeated clicks cannot send duplicate requests.")
    old.isTerminated = true
    actions.checkPending()
    precondition(actions.pendingIDs.isEmpty && actions.message?.contains("已退出") == true)

    let cancel = TestQuitApplication(path: "/Applications/Example.app", pid: 303)
    let delayed = ApplicationActions(runningApplications: { [cancel] })
    let example = Load(id: "example", name: "Example", isApplication: true)
    delayed.quit(example, path: "/Applications/Example.app", fresh: true)
    delayed.checkPending(now: Date().addingTimeInterval(21))
    precondition(delayed.pendingIDs.isEmpty && delayed.message?.contains("仍在运行") == true)
    cancel.acceptsQuit = false
    delayed.quit(example, path: "/Applications/Example.app", fresh: true)
    precondition(delayed.pendingIDs.isEmpty && delayed.message?.contains("未送达") == true)

    let guarded = ApplicationActions(runningApplications: { [cancel] })
    let count = cancel.requests
    guarded.quit(example, path: "/Applications/Example.app", fresh: false)
    guarded.quit(example, path: "/System/Applications/Example.app", fresh: true)
    guarded.quit(example, path: nil, fresh: true)
    precondition(cancel.requests == count)
    let duplicate = TestQuitApplication(path: "/Applications/Example.app", pid: 304)
    let multiple = ApplicationActions(runningApplications: { [cancel, duplicate] })
    multiple.quit(example, path: "/Applications/Example.app", fresh: true)
    precondition(cancel.requests == count && duplicate.requests == 0)

    let own = TestQuitApplication(path: "/Applications/Example.app", pid: getpid())
    let selfGuard = ApplicationActions(runningApplications: { [own] })
    selfGuard.quit(example, path: "/Applications/Example.app", fresh: true)
    precondition(own.requests == 0)
    print("Application exit checks passed (exact target, pending, cancel, stale and duplicate requests).")
}
