import Foundation
import Combine

struct ReleaseVersion: Comparable, CustomStringConvertible {
    private let components: [Int]

    init?(_ text: String) {
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(number), String(value) == number else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct SoftwareRelease: Equatable {
    static let latestURL = URL(string: "https://github.com/CyberWilliam2000/MacPulse/releases/latest")!
    let version: ReleaseVersion
    let url: URL

    init?(url: URL) {
        let prefix = "https://github.com/CyberWilliam2000/MacPulse/releases/tag/v"
        guard url.absoluteString.hasPrefix(prefix),
              let version = ReleaseVersion(String(url.absoluteString.dropFirst(prefix.count))) else { return nil }
        self.version = version
        self.url = url
    }

    static func latest() async throws -> SoftwareRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: StopReleaseRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: latestURL)?.absoluteURL,
              let release = SoftwareRelease(url: url) else { throw URLError(.badServerResponse) }
        return release
    }
}

private final class StopReleaseRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class SoftwareUpdate: ObservableObject {
    enum State: Equatable {
        case ready, checking, current, available(SoftwareRelease), unavailable

        var release: SoftwareRelease? {
            if case .available(let release) = self { return release }
            return nil
        }
    }

    @Published private(set) var state: State = .ready
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private let installed: ReleaseVersion?
    private let fetch: () async throws -> SoftwareRelease

    init(installed: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         fetch: @escaping () async throws -> SoftwareRelease = SoftwareRelease.latest) {
        self.installed = installed.flatMap(ReleaseVersion.init)
        self.fetch = fetch
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer?.tolerance = 10 * 60
    }

    func check() {
        guard checkTask == nil else { return }
        guard let installed else { state = .unavailable; return }
        let previous = state
        if previous.release == nil { state = .checking }
        checkTask = Task { [weak self, fetch] in
            let next: State
            do {
                let release = try await fetch()
                next = installed < release.version ? .available(release) : .current
            } catch {
                next = previous.release == nil ? .unavailable : previous
            }
            self?.state = next
            self?.checkTask = nil
        }
    }

    deinit {
        timer?.invalidate()
        checkTask?.cancel()
    }
}
