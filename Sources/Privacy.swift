import AppKit
import Combine

struct DeviceUse: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case microphone = "麦克风", camera = "摄像头" }
    var id: String
    var kind: Kind
    var application: String
    var process: String
    var pid: Int32?
    var bundle: String?
    var birth: UInt64?
    var device: String
}
struct PrivacyReading {
    var date: Date
    var uses: [DeviceUse]
    var audioOK: Bool
    var cameraOK: Bool
    var defaultInput: String = ""
    var cameras: [String] = []
}
struct PrivacyRecord: Codable, Identifiable {
    var id = UUID()
    var use: DeviceUse
    var firstSeen: Date
    var lastSeen: Date
    var finish: String? // An observation boundary, never an exact capture timestamp.
}

// Separate observation boundaries from exact hardware start/stop times.
struct PrivacyHistory {
    var records: [PrivacyRecord] = []
    var active: [String: UUID] = [:]
    var previous: Date?
    static let gap: TimeInterval = 8
    mutating func consume(_ reading: PrivacyReading) {
        if let previous, reading.date.timeIntervalSince(previous) > Self.gap || reading.date < previous {
            closeAll("监测中断，结束时间未知")
        }
        let present = Set(reading.uses.map(\.id))
        for (key, id) in active {
            guard let i = records.firstIndex(where: { $0.id == id }) else { active.removeValue(forKey: key); continue }
            let known = records[i].use.kind == .microphone ? reading.audioOK : reading.cameraOK
            if !present.contains(key) {
                records[i].finish = known ? "后续采样未再检测到" : "读取中断，结束时间未知"
                active.removeValue(forKey: key)
            }
        }
        for use in reading.uses {
            if let id = active[use.id], let i = records.firstIndex(where: { $0.id == id }) {
                records[i].lastSeen = reading.date
            } else {
                let record = PrivacyRecord(use: use, firstSeen: reading.date, lastSeen: reading.date)
                records.insert(record, at: 0); active[use.id] = record.id
            }
        }
        previous = reading.date
        records = Array(records.filter { reading.date.timeIntervalSince($0.lastSeen) < 30 * 86400 }.prefix(500))
        let retained = Set(records.map(\.id))
        active = active.filter { retained.contains($0.value) }
    }
    mutating func closeAll(_ reason: String) {
        for i in records.indices where records[i].finish == nil { records[i].finish = reason }
        active.removeAll()
    }
    mutating func restore(_ saved: [PrivacyRecord]) {
        records = saved
        closeAll("上次监测已结束，结束时间未知")
        previous = nil
    }
}

private func privacyString<T>(_ value: T) -> String {
    var copy = value
    return withUnsafeBytes(of: &copy) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
func readPrivacy() -> PrivacyReading {
    var raw = pulse_privacy()
    let microphoneCount = Int(raw.microphoneCount), cameraCount = Int(raw.cameraCount)
    var uses = [DeviceUse]()
    withUnsafePointer(to: &raw.microphones) { ptr in
        ptr.withMemoryRebound(to: MicrophoneUse.self, capacity: 128) { rows in
            for i in 0..<microphoneCount {
                let row = rows[i]
                var path = [CChar](repeating: 0, count: 4096)
                let found = pulse_process_path(row.pid, &path, Int32(path.count))
                let fullPath = found > 0 ? String(cString: path) : ""
                let appPath = fullPath.range(of: ".app/").map { String(fullPath[..<$0.lowerBound]) + ".app" }
                let app = appPath.flatMap { Bundle(path: $0) }
                let bundle = privacyString(row.bundle)
                let appName = (app?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (app?.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ??
                    (bundle.isEmpty ? "未知应用" : bundle)
                let device = privacyString(row.device)
                uses.append(DeviceUse(id: "mic:\(row.pid):\(row.start):\(row.deviceID)", kind: .microphone,
                                      application: appName, process: URL(fileURLWithPath: fullPath).lastPathComponent,
                                      pid: row.pid, bundle: bundle.isEmpty ? nil : bundle, birth: row.birth == 0 ? nil : row.birth,
                                      device: device.isEmpty ? "设备未知" : device))
            }
        }
    }
    var cameras = [String]()
    withUnsafePointer(to: &raw.cameras) { ptr in
        ptr.withMemoryRebound(to: CameraState.self, capacity: 32) { rows in
            for i in 0..<cameraCount {
                let row = rows[i]; let name = privacyString(row.name)
                let label = name.isEmpty ? "未知摄像头" : name
                cameras.append(label + (row.running == 1 ? " · 正在使用" : row.running == 0 ? " · 未在使用" : " · 状态未知"))
                if row.running == 1 {
                    uses.append(DeviceUse(id: "camera:\(row.deviceID)", kind: .camera,
                                          application: "应用未知", process: "", device: label))
                }
            }
        }
    }
    return PrivacyReading(date: Date(), uses: uses, audioOK: raw.audioOK == 1 && raw.audioPartial == 0,
                          cameraOK: raw.cameraOK == 1 && raw.cameraPartial == 0,
                          defaultInput: privacyString(raw.defaultInput), cameras: cameras)
}

final class PrivacyMonitor: ObservableObject {
    @Published private(set) var reading: PrivacyReading?
    @Published private(set) var history = PrivacyHistory()
    @Published private(set) var storageError: String?
    private let storage: URL
    private let queue = DispatchQueue(label: "MacPulse.privacy", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastSave = Date.distantPast

    init(storage: URL? = nil) {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPulse/privacy-history.json")
        if FileManager.default.fileExists(atPath: self.storage.path) {
            do { history.restore(try JSONDecoder().decode([PrivacyRecord].self, from: Data(contentsOf: self.storage))) }
            catch { storageError = "历史记录读取失败：\(error.localizedDescription)" }
        }
    }
    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 2)
        source.setEventHandler { [weak self] in
            let result = readPrivacy()
            DispatchQueue.main.async { self?.accept(result) }
        }
        timer = source; source.resume()
    }
    func accept(_ result: PrivacyReading) {
        let oldActive = history.active
        history.consume(result); reading = result
        if history.active != oldActive || Date().timeIntervalSince(lastSave) >= 30 { save() }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history.records).write(to: storage, options: .atomic)
            storageError = nil; lastSave = Date()
        } catch { storageError = "历史记录保存失败：\(error.localizedDescription)" }
    }
    deinit { timer?.cancel() }
}
