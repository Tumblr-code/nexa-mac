import AppKit
import Combine
import Darwin

struct AppIdentity: Equatable {
    let id: String
    let name: String
    let path: String

    init(id: String, name: String, path: String = "") {
        self.id = id; self.name = name; self.path = path
    }

    init?(_ app: NSRunningApplication) {
        guard !app.isTerminated, let url = app.bundleURL,
              app.activationPolicy != .prohibited else { return nil }
        self.init(id: app.bundleIdentifier ?? url.path,
                  name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                  path: url.path)
    }
}

struct RunningApp {
    let identity: AppIdentity
    let pid: pid_t
}

struct AppResource: Identifiable {
    let app: AppIdentity
    var cpu: Double?
    var memory: UInt64?
    var processCount: Int
    var partial: Bool
    var pid: pid_t
    var id: String { app.id }
}

struct ProcessReading {
    let pid: pid_t
    let parent: pid_t
    let path: String
    let started: UInt64
    let cpu: UInt64?
    let memory: UInt64?
}

enum ActivityMath {
    // proc_pid_rusage reports CPU time in Mach ticks, which are not nanoseconds on Apple Silicon.
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()
    static func nanoseconds(ticks: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        guard denom > 0 else { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: numer)
        guard high < denom else { return .max }
        return denom.dividingFullWidth((high, low)).quotient
    }
    static func cpu(previous: UInt64, current: UInt64, elapsed: Double, cores: Int) -> Double? {
        guard elapsed > 0, elapsed.isFinite, cores > 0, current >= previous else { return nil }
        return min(100, Double(current - previous) / 1_000_000_000 / elapsed / Double(cores) * 100)
    }
    // A helper app bundled inside another running app belongs to that app, not to a row of its own.
    static func topLevel(_ apps: [RunningApp]) -> [RunningApp] {
        apps.filter { app in
            !apps.contains { $0.identity.id != app.identity.id && !$0.identity.path.isEmpty &&
                app.identity.path.hasPrefix($0.identity.path + "/") }
        }
    }
    static func owner(_ process: ProcessReading, roots: [RunningApp], processes: [pid_t: ProcessReading]) -> String? {
        if let exact = roots.first(where: { $0.pid == process.pid }) { return exact.identity.id }
        if let path = roots.first(where: { process.path.hasPrefix($0.identity.path + "/") }) {
            return path.identity.id
        }
        var parent = process.parent
        var visited: Set<pid_t> = [process.pid]
        while parent > 1, visited.insert(parent).inserted {
            if let root = roots.first(where: { $0.pid == parent }) { return root.identity.id }
            guard let ancestor = processes[parent] else { break }
            parent = ancestor.parent
        }
        return nil
    }
}

final class AppResourceSampler {
    private var previous: [pid_t: (started: UInt64, cpu: UInt64)] = [:]
    private var previousTime: Double?

    func reset() { previous.removeAll(); previousTime = nil }

    func sample(apps: [RunningApp]) -> [AppResource] {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 } ?? 0
        let processes = readProcesses()
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var grouped: [String: [ProcessReading]] = [:]
        for process in processes {
            if let owner = ActivityMath.owner(process, roots: apps, processes: byPID) {
                grouped[owner, default: []].append(process)
            }
        }
        var seen: Set<String> = []
        let result = apps.filter { seen.insert($0.identity.id).inserted }.map { app -> AppResource in
            let members = grouped[app.identity.id] ?? []
            let memory = members.compactMap(\.memory)
            let usage = members.compactMap { process -> Double? in
                guard let cpu = process.cpu, let previous = previous[process.pid],
                      previous.started == process.started else { return nil }
                return ActivityMath.cpu(previous: previous.cpu, current: cpu, elapsed: elapsed,
                                        cores: ProcessInfo.processInfo.activeProcessorCount)
            }
            return AppResource(app: app.identity, cpu: usage.isEmpty ? nil : min(100, usage.reduce(0, +)),
                memory: memory.isEmpty ? nil : memory.reduce(0, +), processCount: members.count,
                partial: memory.count < members.count || members.isEmpty, pid: app.pid)
        }
        previous = Dictionary(uniqueKeysWithValues: processes.compactMap { process in
            process.cpu.map { (process.pid, (process.started, $0)) }
        })
        previousTime = now
        return result
    }

    private func readProcesses() -> [ProcessReading] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let actual = proc_listallpids(&pids, capacity)
        guard actual > 0 else { return [] }
        return pids.prefix(min(Int(actual), pids.count)).compactMap { pid in
            guard pid > 0 else { return nil }
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == getuid() else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            let pathResult = proc_pidpath(pid, &path, UInt32(path.count))
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            let stamp = UInt64(bsd.pbi_start_tvsec) &* 1_000_000 &+ UInt64(bsd.pbi_start_tvusec)
            return ProcessReading(pid: pid, parent: pid_t(bsd.pbi_ppid),
                path: pathResult > 0 ? String(cString: path) : "", started: stamp,
                cpu: result == 0 ? ActivityMath.nanoseconds(ticks: info.ri_user_time &+ info.ri_system_time,
                    numer: ActivityMath.timebase.numer, denom: ActivityMath.timebase.denom) : nil,
                memory: result == 0 ? info.ri_phys_footprint : nil)
        }
    }
}

final class AppActivityMonitor: ObservableObject {
    @Published private(set) var apps: [AppResource] = []
    @Published private(set) var foreground: String?
    @Published private(set) var sampledAt: Date?
    private let sampler = AppResourceSampler()
    private let queue = DispatchQueue(label: "cn.nexastore.nexa.apps", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private var busy = false
    private var holders: Set<String> = []
    private var suspended = false

    var busiest: AppResource? {
        apps.filter { $0.cpu != nil }.max { ($0.cpu ?? 0, $1.app.name) < ($1.cpu ?? 0, $0.app.name) }
    }

    static func runningApps() -> [RunningApp] {
        ActivityMath.topLevel(NSWorkspace.shared.runningApplications.compactMap { app in
            AppIdentity(app).map { RunningApp(identity: $0, pid: app.processIdentifier) }
        })
    }
    // The panel and the window share one sampler; it only runs while one of them is on screen.
    func hold(_ client: String) {
        holders.insert(client)
        if !suspended { start() }
    }
    func drop(_ client: String) {
        holders.remove(client)
        // Deferred so handing over from the panel to the window keeps the CPU baseline.
        DispatchQueue.main.async { if self.holders.isEmpty { self.stop() } }
    }
    func suspend() { suspended = true; stop() }
    func resume() {
        suspended = false
        if !holders.isEmpty { start() }
    }
    private func start() {
        guard timer == nil else { return }
        generation += 1
        queue.async { self.sampler.reset() }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.3
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func sample() {
        guard !busy else { return }
        busy = true
        let current = generation
        let roots = Self.runningApps()
        let front = NSWorkspace.shared.frontmostApplication.flatMap(AppIdentity.init)?.id
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.sampler.sample(apps: roots)
            DispatchQueue.main.async {
                self.busy = false
                guard current == self.generation else {
                    // A restart arrived mid-read; take its first reading now rather than a tick late.
                    if self.timer != nil { self.sample() }
                    return
                }
                self.apps = result
                self.foreground = front
                self.sampledAt = Date()
            }
        }
    }
    private func stop() {
        timer?.invalidate(); timer = nil
        generation += 1
    }
}

enum ActivitySort: String, CaseIterable {
    case cpu = "CPU", memory = "内存", name = "名称"
}

enum ActivityQuery {
    static func rows(apps: [AppResource], search: String, sort: ActivitySort) -> [AppResource] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter {
            query.isEmpty || $0.app.name.localizedStandardContains(query) ||
            $0.app.id.localizedStandardContains(query) || String($0.pid).contains(query)
        }.sorted { lhs, rhs in
            let a: Double
            let b: Double
            switch sort {
            case .cpu: a = lhs.cpu ?? -1; b = rhs.cpu ?? -1
            case .memory: a = lhs.memory.map(Double.init) ?? -1; b = rhs.memory.map(Double.init) ?? -1
            case .name: a = 0; b = 0
            }
            if a != b { return a > b }
            let order = lhs.app.name.localizedStandardCompare(rhs.app.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
