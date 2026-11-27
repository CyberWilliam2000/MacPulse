import Foundation
import Combine

enum Metric: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, disk, heat
    var id: Self { self }
    var title: String {
        switch self { case .cpu: "CPU"; case .memory: "内存"; case .disk: "磁盘"; case .heat: "温度" }
    }
}

struct Load: Identifiable, Codable {
    var id: String
    var name: String
    var cpu: Double = 0
    var memory: Double = 0
    var read: Double = 0
    var write: Double = 0
    var members: Int = 0
    var isApplication: Bool?

    func value(_ metric: Metric) -> Double {
        switch metric { case .cpu, .heat: cpu; case .memory: memory; case .disk: read + write }
    }
}

struct ProcessReading: Identifiable, Codable {
    let pid: Int32
    let name: String
    let application: String
    let cpu: Double?
    let memory: Double
    let read: Double?
    let write: Double?
    var taskType: String?
    var taskService: String?
    var rendererID: String?
    var parentPID: Int32?
    var birth: UInt64?
    var id: Int32 { pid }

    func value(_ metric: Metric) -> Double? {
        switch metric {
        case .cpu, .heat: return cpu
        case .memory: return memory
        case .disk:
            guard let read, let write else { return nil }
            return read + write
        }
    }

    func display(_ metric: Metric) -> String {
        switch metric {
        case .cpu, .heat:
            if let cpu, cpu > 0, cpu < 1 { return String(format: "%.1f%%", cpu) }
            return percent(cpu)
        case .memory: return size(memory)
        case .disk: return rate(value(.disk))
        }
    }

    var role: String? {
        switch name {
        case "swift-frontend": return "Swift 编译或脚本"
        case "swiftc": return "Swift 编译"
        case "clang", "clang++": return "C / C++ 编译"
        case "mds", "mds_stores", "mdworker", "mdworker_shared": return "Spotlight 索引"
        case "node_repl": return "Node 工具会话"
        default: return name.localizedCaseInsensitiveContains("Renderer") ? "界面渲染" : nil
        }
    }
}

extension Array where Element == ProcessReading {
    func ranked(for metric: Metric) -> [ProcessReading] {
        sorted {
            let a = $0.value(metric) ?? -1
            let b = $1.value(metric) ?? -1
            return a == b ? $0.pid < $1.pid : a > b
        }
    }
}

struct Sample: Identifiable, Codable {
    var id: Date
    var cpu: Double?
    var pressure: Int? // Dispatch/vm pressure flags: 1 normal, 2 warning, 4 critical
    var swapUsed: Double?
    var swapRead: Double?
    var swapWrite: Double?
    var compressed: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var diskOps: Double?
    var diskMS: Double?
    var free: Double?
    var capacity: Double?
    var thermal: Int
    var temperature: Double?
    var sensor: String?
    var sensorCount: Int
    var sources: [Load]
    var listed: Int
    var readable: Int
    var processes: [ProcessReading]? // Optional for records from earlier versions.

    func ranking(_ metric: Metric) -> [Load] {
        sources.filter { $0.value(metric) > 0 }.sorted { $0.value(metric) > $1.value(metric) }
    }

    var pressureLabel: String {
        switch pressure { case 1: "正常"; case 2: "升高"; case 4: "压力高"; default: "未知" }
    }
    var thermalLabel: String {
        switch thermal { case 0: "正常"; case 1: "升高"; case 2: "较高"; case 3: "严重"; default: "未知" }
    }
    var diskTotal: Double? {
        guard let diskRead, let diskWrite else { return nil }
        return diskRead + diskWrite
    }
    var swapTotal: Double? {
        guard let swapRead, let swapWrite else { return nil }
        return swapRead + swapWrite
    }
}

struct Incident: Identifiable, Codable {
    var id: Date
    var samples: [Sample]
}

let miB: Double = 1_048_576
let giB: Double = 1_073_741_824
func size(_ bytes: Double?) -> String {
    guard let bytes else { return "—" }
    if bytes >= giB { return String(format: "%.1f GB", bytes / giB) }
    if bytes >= miB { return String(format: "%.1f MB", bytes / miB) }
    if bytes >= 1024 { return String(format: "%.0f KB", bytes / 1024) }
    return bytes > 0 ? String(format: "%.0f B", bytes) : "0"
}
func rate(_ bytes: Double?) -> String { bytes.map { $0 == 0 ? "0 MB/s" : size($0) + "/s" } ?? "—" }
func percent(_ n: Double?) -> String { n.map { String(format: "%.0f%%", $0) } ?? "—" }
func degrees(_ n: Double?) -> String { n.map { String(format: "%.0f °C", $0) } ?? "—" }
func clockLabel(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().second()) }

final class Sampler {
    private var baseline: SystemProbe?
    private var processBaseline = [Int32: ProcessProbe]()
    private struct ProcessLabel {
        let start: UInt64
        let key: String
        let name: String
        let executable: String
        let app: Bool
        var taskType: String?
        var taskService: String?
        var rendererID: String?
    }
    private var labels = [Int32: ProcessLabel]()
    private(set) var processesByGroup = [String: [ProcessReading]]()
    private(set) var applicationPaths = [String: String]()
    private var lastUptime: TimeInterval?
    private var lastTemperature = TemperatureProbe()
    private var lastTemperatureTime = -Double.infinity
    // Read on the same serial queue as sample(). Used only when the initial level cannot be queried.
    var pressureEvent: Int?

    private func delta(_ a: UInt64, _ b: UInt64) -> Double? { b >= a ? Double(b - a) : nil }

    func sample() -> Sample {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let seconds = lastUptime.map { uptime - $0 } ?? 0
        let continuous = seconds > 0 && seconds < 12
        lastUptime = uptime
        let system = pulse_system()
        let old = continuous ? baseline : nil
        baseline = system
        var cpu: Double?
        if let old, old.cpuOK != 0, system.cpuOK != 0 {
            let b = system.ticks, a = old.ticks
            let user = Double(b.0 &- a.0)
            let sys = Double(b.1 &- a.1)
            let idle = Double(b.2 &- a.2)
            let nice = Double(b.3 &- a.3)
            let total = user + nice + sys + idle
            if total > 0 { cpu = (user + nice + sys) / total * 100 }
        }

        var s = Sample(
            id: now, cpu: cpu, pressure: [1, 2, 4].contains(Int(system.pressure)) ? Int(system.pressure) : pressureEvent,
            swapUsed: system.swapOK != 0 ? Double(system.swapUsed) : nil,
            compressed: system.vmOK != 0 ? Double(system.compressed) : nil,
            free: system.totalBytes > 0 ? Double(system.freeBytes) : nil,
            capacity: system.totalBytes > 0 ? Double(system.totalBytes) : nil,
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            sensorCount: 0, sources: [], listed: 0, readable: 0
        )
        if let old, old.vmOK != 0, system.vmOK != 0 {
            s.swapRead = delta(old.swapIn, system.swapIn).map { $0 / seconds }
            s.swapWrite = delta(old.swapOut, system.swapOut).map { $0 / seconds }
        }
        if let old, old.diskOK != 0, system.diskOK != 0, old.diskIdentity == system.diskIdentity {
            s.diskRead = delta(old.diskRead, system.diskRead).map { $0 / seconds }
            s.diskWrite = delta(old.diskWrite, system.diskWrite).map { $0 / seconds }
            if let ops = delta(old.diskOps, system.diskOps) {
                s.diskOps = ops / seconds
                if ops > 0 { s.diskMS = delta(old.diskTime, system.diskTime).map { $0 / ops / 1_000_000 } }
            }
        }
        if uptime - lastTemperatureTime >= 5 {
            lastTemperature = pulse_temperature()
            lastTemperatureTime = uptime
        }
        if lastTemperature.count > 0 {
            s.temperature = lastTemperature.celsius
            s.sensor = withUnsafeBytes(of: lastTemperature.name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            s.sensorCount = Int(lastTemperature.count)
        }

        let capacity = pulse_process_capacity()
        var raw = [ProcessProbe](repeating: ProcessProbe(), count: Int(capacity))
        var listed: Int32 = 0
        let n = Int(pulse_processes(&raw, capacity, &listed))
        s.listed = Int(listed)
        s.readable = n
        let current = Dictionary(raw.prefix(n).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        labels = labels.filter { current[$0.key]?.start == $0.value.start }
        for p in current.values where labels[p.pid] == nil {
            func flag<T>(_ field: T) -> String? {
                withUnsafeBytes(of: field) { raw in
                    let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                    return text.isEmpty ? nil : text
                }
            }
            var nameBuffer = [CChar](repeating: 0, count: 4096)
            let named = pulse_process_path(p.pid, &nameBuffer, Int32(nameBuffer.count)) != 0
            let path = named ? String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            let executable = path.isEmpty ? "未知进程" : (path as NSString).lastPathComponent
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.upperBound].dropLast())
                let name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                labels[p.pid] = ProcessLabel(start: p.start, key: bundle, name: name == "MacPulse" ? "Mac 脉搏" : name,
                                             executable: executable, app: true)
            } else {
                let name = path.isEmpty ? "进程 \(p.pid)" : executable
                labels[p.pid] = ProcessLabel(start: p.start, key: path.isEmpty ? "pid:\(p.pid)" : path, name: name,
                                             executable: executable, app: false)
            }
            let task = labels[p.pid]?.app == true ? pulse_task(p.pid) : TaskProbe()
            let type = flag(task.type)
            let main = labels[p.pid]?.app == true &&
                (Bundle(path: labels[p.pid]!.key)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) == executable
            labels[p.pid]?.taskType = type ?? (main ? "app-main" : nil)
            let service = flag(task.service), renderer = flag(task.renderer)
            labels[p.pid]?.taskService = service
            labels[p.pid]?.rendererID = renderer
        }
        var grouped = [String: Load]()
        var members = [String: [ProcessReading]]()
        var applicationPaths = [String: String]()
        var readings = [ProcessReading]()
        for p in current.values {
            guard let ownLabel = labels[p.pid] else { continue }
            var label = ownLabel
            if !label.app {
                var parent = p.parent
                for _ in 0..<8 {
                    guard parent > 1, let pp = current[parent], pp.start <= p.start else { break }
                    if let app = labels[parent], app.app { label = app; break }
                    if pp.parent == parent { break }
                    parent = pp.parent
                }
            }
            var cpu: Double?
            var read: Double?
            var write: Double?
            if continuous, let previous = processBaseline[p.pid], previous.start == p.start {
                cpu = delta(previous.cpuNS, p.cpuNS).map { $0 / 1e9 / seconds * 100 }
                read = delta(previous.read, p.read).map { $0 / seconds }
                write = delta(previous.write, p.write).map { $0 / seconds }
            }
            // Use a stable ID for this launch without persisting an executable path.
            let id = String(label.key.hashValue)
            let reading = ProcessReading(pid: p.pid, name: ownLabel.executable, application: label.name,
                                         cpu: cpu, memory: Double(p.memory), read: read, write: write,
                                         taskType: ownLabel.taskType, taskService: ownLabel.taskService,
                                         rendererID: ownLabel.rendererID, parentPID: p.parent, birth: p.start)
            var load = grouped[id] ?? Load(id: id, name: label.name)
            load.isApplication = label.app && !label.key.hasPrefix("/System/") && !label.key.hasPrefix("/usr/")
            if load.isApplication == true { applicationPaths[id] = label.key }
            load.members += 1
            load.cpu += cpu ?? 0
            load.memory += reading.memory
            load.read += read ?? 0
            load.write += write ?? 0
            grouped[id] = load
            members[id, default: []].append(reading)
            readings.append(reading)
        }
        processBaseline = current
        processesByGroup = members
        self.applicationPaths = applicationPaths
        // Keep leaders for every resource, without storing filesystem paths or process arguments.
        var ids = Set<String>()
        var seen = Set<Int32>()
        var top = [ProcessReading]()
        for metric in [Metric.cpu, .memory, .disk] {
            ids.formUnion(grouped.values.sorted { $0.value(metric) > $1.value(metric) }.prefix(8).map(\.id))
            for reading in readings.ranked(for: metric).prefix(while: { ($0.value(metric) ?? 0) > 0 }).prefix(5)
                where seen.insert(reading.pid).inserted {
                top.append(reading)
            }
        }
        s.sources = ids.sorted().compactMap { grouped[$0] }
        s.processes = top
        return s
    }
}

final class Monitor: ObservableObject {
    @Published private(set) var samples = [Sample]()
    @Published private(set) var incidents = [Incident]()
    private(set) var processesByGroup = [String: [ProcessReading]]()
    private(set) var applicationPaths = [String: String]()
    private(set) var processTraces = [Int32: [ProcessObservation]]()
    private let queue = DispatchQueue(label: "MacPulse.sampler", qos: .utility)
    private let sampler = Sampler()
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private let storage: URL

    init(storage override: URL? = nil) {
        storage = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPulse/incidents.json")
        if let existing = try? Data(contentsOf: storage),
           let saved = try? JSONDecoder().decode([Incident].self, from: existing) { incidents = saved }
    }

    func start() {
        guard timer == nil else { return }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            let state = source.data
            self.sampler.pressureEvent = state.contains(.critical) ? 4 : state.contains(.warning) ? 2 : 1
        }
        pressureSource = pressure
        pressure.resume()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let sample = self.sampler.sample()
            let processes = self.sampler.processesByGroup
            let paths = self.sampler.applicationPaths
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cutoff = sample.id.addingTimeInterval(-300)
                var next = self.samples.filter { $0.id >= cutoff && $0.id < sample.id }
                next.append(sample)
                self.processesByGroup = processes
                self.applicationPaths = paths
                let all = processes.values.flatMap { $0 }
                let alive = Set(all.map(\.pid))
                self.processTraces = self.processTraces.filter { alive.contains($0.key) }
                for reading in all {
                    var trace = (self.processTraces[reading.pid] ?? []).filter {
                        $0.reading.birth == reading.birth && sample.id.timeIntervalSince($0.date) <= 24
                    }
                    trace.append(ProcessObservation(date: sample.id, reading: reading))
                    self.processTraces[reading.pid] = trace
                }
                self.samples = next
            }
        }
        timer = source
        source.resume()
    }

    @discardableResult
    func mark(_ date: Date = Date()) -> Bool {
        let recent = samples.filter { date.timeIntervalSince($0.id) >= 0 && date.timeIntervalSince($0.id) <= 300 }
        guard let last = recent.last, date.timeIntervalSince(last.id) < 12 else { return false }
        return save(Array(([Incident(id: date, samples: recent)] + incidents).prefix(12)))
    }

    @discardableResult
    func remove(_ id: Date) -> Bool { save(incidents.filter { $0.id != id }) }

    private func save(_ next: [Incident]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: storage, options: .atomic)
            incidents = next
            return true
        } catch {
            return false
        }
    }
}
