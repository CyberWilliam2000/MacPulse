import AppKit

private final class TestQuitApplication: QuitApplication {
    var bundleURL: URL?
    var processIdentifier: pid_t
    var isTerminated = false
    var acceptsQuit = true
    var requests = 0
    var forceRequests = 0
    var acceptsForce = true

    init(path: String, pid: pid_t) {
        bundleURL = URL(fileURLWithPath: path)
        processIdentifier = pid
    }

    func forceTerminate() -> Bool {
        forceRequests += 1
        return acceptsForce
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
    let forceOld = TestQuitApplication(path: "/Applications/WeChat 3.8.10.app", pid: 401)
    let forceNew = TestQuitApplication(path: "/Applications/WeChat.app", pid: 402)
    let force = ApplicationActions(runningApplications: { [forceOld, forceNew] }, processBirth: { _ in 900 })
    var identified = Load(id: "force-old", name: "Old WeChat", isApplication: true, applicationPID: 401, applicationBirth: 900)
    force.forceQuit(identified, path: "/Applications/WeChat 3.8.10.app", fresh: true)
    precondition(forceOld.forceRequests == 1 && forceOld.requests == 0 && forceNew.forceRequests == 0)
    precondition(force.pendingIDs.contains(identified.id) && force.message?.contains("已关闭") == false)
    force.forceQuit(identified, path: "/Applications/WeChat 3.8.10.app", fresh: true)
    precondition(forceOld.forceRequests == 1)
    forceOld.isTerminated = true
    force.checkPending()
    precondition(force.pendingIDs.isEmpty && force.message?.contains("已关闭") == true)

    identified.applicationPID = 402
    let identityGuard = ApplicationActions(runningApplications: { [forceNew] }, processBirth: { _ in 901 })
    identityGuard.forceQuit(identified, path: "/Applications/WeChat.app", fresh: true)
    precondition(forceNew.forceRequests == 0, "A reused PID or restarted application cannot be force-quit from an old row.")
    identified.applicationBirth = nil
    force.forceQuit(identified, path: "/Applications/WeChat.app", fresh: true)
    precondition(forceNew.forceRequests == 0)
    identified.applicationBirth = 900
    force.forceQuit(identified, path: "/Applications/WeChat.app", fresh: false)
    force.forceQuit(identified, path: "/System/Applications/WeChat.app", fresh: true)
    precondition(forceNew.forceRequests == 0)
    forceNew.acceptsForce = false
    force.forceQuit(identified, path: "/Applications/WeChat.app", fresh: true)
    precondition(force.pendingIDs.isEmpty && force.message?.contains("未送达") == true)
    forceNew.acceptsForce = true
    force.forceQuit(identified, path: "/Applications/WeChat.app", fresh: true)
    force.checkPending(now: Date().addingTimeInterval(9))
    precondition(force.message?.contains("未完成") == true && force.message?.contains("已关闭") == false)
    let forceSelf = ApplicationActions(runningApplications: { [own] }, processBirth: { _ in 900 })
    var selfLoad = example; selfLoad.applicationPID = getpid(); selfLoad.applicationBirth = 900
    forceSelf.forceQuit(selfLoad, path: "/Applications/Example.app", fresh: true)
    precondition(own.forceRequests == 0)
    print("Application actions passed (normal/force, exact instance, PID birth, completion, timeout, stale, self/system, duplicate requests).")
}
