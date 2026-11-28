import Foundation

@main
struct SoftwareUpdateTests {
    @MainActor
    static func main() async throws {
        let url = URL(string: "https://github.com/CyberWilliam2000/MacPulse/releases/tag/v0.10.0")!
        let release = SoftwareRelease(url: url)!
        precondition(ReleaseVersion("0.9.2")! < release.version)
        precondition(ReleaseVersion("1.0.0")! > release.version)
        precondition(SoftwareRelease(url: url.appendingPathComponent("other")) == nil)
        precondition(SoftwareRelease(url: URL(string: url.absoluteString + "-beta.1")!) == nil)
        precondition(SoftwareRelease(url: URL(string: url.absoluteString.replacingOccurrences(of: "github.com", with: "example.com"))!) == nil)

        var fetchCount = 0
        let update = SoftwareUpdate(installed: "0.9.2") {
            fetchCount += 1
            if fetchCount == 2 { throw URLError(.notConnectedToInternet) }
            return release
        }
        update.check()
        update.check()
        while fetchCount < 1 { await Task.yield() }
        precondition(fetchCount == 1 && update.state == .available(release))
        update.check()
        while fetchCount < 2 { await Task.yield() }
        precondition(update.state == .available(release))

        let current = SoftwareUpdate(installed: "0.10.0") { release }
        current.check()
        while current.state == .checking { await Task.yield() }
        precondition(current.state == .current)

        let offline = SoftwareUpdate(installed: "0.9.2") { throw URLError(.notConnectedToInternet) }
        offline.check()
        while offline.state == .checking { await Task.yield() }
        precondition(offline.state == .unavailable)

        if CommandLine.arguments.contains("--live") {
            print("GitHub latest tag:", try await SoftwareRelease.latest().version)
        }
        print("Software update checks passed (numeric version ordering, trusted release URLs, current, newer, offline and duplicate checks).")
    }
}
