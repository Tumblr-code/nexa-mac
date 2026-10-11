import Foundation
import Combine
import Darwin
import SystemConfiguration

enum StatsMath {
    static func cpu(previous: [UInt32], current: [UInt32]) -> (Double, Double, Double)? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        let user = (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total * 100
        let system = delta[Int(CPU_STATE_SYSTEM)] / total * 100
        return (min(100, max(0, user + system)), user, system)
    }

    static func rate(previous: UInt64, current: UInt64, elapsed: Double) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }

    static func memory(internalPages: UInt64, purgeable: UInt64, wired: UInt64,
                       compressed: UInt64, pageSize: UInt64, total: UInt64) -> UInt64 {
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return min(total, (app + wired + compressed) * pageSize)
    }
}

enum TrendMath {
    // Samples are placed by age, so a pause or a slow refresh stays a gap instead of being stretched.
    static func points(_ samples: [(age: Double, value: Double)], window: Double,
                       ceiling: Double = 100) -> [(x: Double, y: Double)] {
        guard window > 0, window.isFinite, ceiling > 0, ceiling.isFinite else { return [] }
        return samples.filter { $0.age.isFinite && $0.value.isFinite && $0.age >= 0 && $0.age <= window }
            .map { (x: 1 - $0.age / window, y: min(1, max(0, $0.value / ceiling))) }
            .sorted { $0.x < $1.x }
    }
    // A mostly idle machine would draw a flat line on a 0–100 scale, so the plot zooms in, but never past 25%.
    static func ceiling(peak: Double?) -> Double {
        guard let peak, peak.isFinite else { return 25 }
        return min(100, max(25, (peak / 25).rounded(.up) * 25))
    }
    static func fraction(_ part: UInt64?, of total: UInt64?) -> Double? {
        guard let part, let total, total > 0 else { return nil }
        return min(1, Double(part) / Double(total))
    }
}

struct CPUPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

struct Snapshot {
    var cpu: Double?
    var userCPU: Double?
    var systemCPU: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryPressure: Int?
    var swapUsed: UInt64?
    var diskTotal: UInt64?
    var diskFree: UInt64?
    var download: Double?
    var upload: Double?
    var networkName = "检测中"
    var networkConnected = false
    var sampledAt: Date?
    var history: [CPUPoint] = []
    var thermalState: ProcessInfo.ThermalState = .nominal

    var trend: [(x: Double, y: Double)] {
        // A point is stamped just after its sample, so the newest one can be a hair ahead of sampledAt.
        let now = max(sampledAt ?? Date(), history.last?.time ?? .distantPast)
        return TrendMath.points(history.map { (age: now.timeIntervalSince($0.time), value: $0.value) },
                                window: 60, ceiling: trendCeiling)
    }
    var peakCPU: Double? { history.map(\.value).max() }
    var trendCeiling: Double { TrendMath.ceiling(peak: peakCPU) }
    var memoryFraction: Double? { TrendMath.fraction(memoryUsed, of: memoryTotal) }
    var diskFraction: Double? {
        guard let diskTotal, let diskFree, diskFree <= diskTotal else { return nil }
        return TrendMath.fraction(diskTotal - diskFree, of: diskTotal)
    }

    var pressureText: String {
        switch memoryPressure {
        case 1: return "正常"
        case 2: return "偏高"
        case 4: return "较高"
        default: return "暂不可用"
        }
    }

    var status: String {
        if sampledAt == nil { return "正在采集" }
        if thermalState == .critical || thermalState == .serious { return "系统温度较高" }
        if memoryPressure == 4 { return "内存压力较高" }
        if memoryPressure == 2 { return "内存压力偏高" }
        if let cpu, cpu > 85 { return "处理器繁忙" }
        return cpu == nil || memoryUsed == nil ? "部分数据不可用" : "运行正常"
    }

    var warning: Bool {
        memoryPressure == 2 || memoryPressure == 4 || (cpu ?? 0) > 85 ||
        thermalState == .critical || thermalState == .serious
    }
}

enum Units {
    static let gib = 1_073_741_824.0
    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.1f", Double(bytes) / gib)
    }
    static func disk(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.0f", Double(bytes) / 1_000_000_000)
    }
    static func speed(_ bytes: Double?) -> (String, String) {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return ("—", "KB/s") }
        if bytes >= 1_000_000 { return (String(format: "%.1f", bytes / 1_000_000), "MB/s") }
        return (String(format: "%.0f", bytes / 1_000), "KB/s")
    }
}

final class MetricsSampler {
    private let host = mach_host_self()
    private var lastCPU: [UInt32]?
    private var lastNetwork: (name: String, rx: UInt64, tx: UInt64, time: Double)?
    private var cachedDisk: (total: UInt64, free: UInt64)?
    private var lastDiskTime = -Double.infinity
    private let store = SCDynamicStoreCreate(nil, "cn.nexastore.nexa" as CFString, nil, nil)
    private lazy var interfaceTypes: [String: String] = {
        var types: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) else { continue }
            types[bsd as String] = SCNetworkInterfaceGetInterfaceType(interface) as String?
        }
        return types
    }()

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func reset() {
        lastCPU = nil
        lastNetwork = nil
        lastDiskTime = -Double.infinity
    }

    func sample() -> Snapshot {
        var result = Snapshot()
        result.sampledAt = Date()
        result.thermalState = ProcessInfo.processInfo.thermalState
        readCPU(into: &result)
        readMemory(into: &result)
        readNetwork(into: &result)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDiskTime >= 30 {
            lastDiskTime = now
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let total = attributes[.systemSize] as? NSNumber,
               let free = attributes[.systemFreeSize] as? NSNumber {
                cachedDisk = (total.uint64Value, free.uint64Value)
            } else { cachedDisk = nil }
        }
        result.diskTotal = cachedDisk?.total
        result.diskFree = cachedDisk?.free
        return result
    }

    private func readCPU(into result: inout Snapshot) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { lastCPU = nil; return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        if let previous = lastCPU, let usage = StatsMath.cpu(previous: previous, current: ticks) {
            result.cpu = usage.0
            result.userCPU = usage.1
            result.systemCPU = usage.2
        }
        lastCPU = ticks
    }

    private func readMemory(into result: inout Snapshot) {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            result.memoryUsed = StatsMath.memory(internalPages: UInt64(info.internal_page_count),
                purgeable: UInt64(info.purgeable_count), wired: UInt64(info.wire_count),
                compressed: UInt64(info.compressor_page_count),
                pageSize: UInt64(vm_kernel_page_size), total: result.memoryTotal)
        }
        var pressure: Int32 = 0
        var size = MemoryLayout.size(ofValue: pressure)
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 {
            result.memoryPressure = Int(pressure)
        }
        var swap = xsw_usage()
        size = MemoryLayout.size(ofValue: swap)
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { result.swapUsed = swap.xsu_used }
    }

    private func readNetwork(into result: inout Snapshot) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else {
            result.networkName = "暂不可用"
            lastNetwork = nil
            return
        }
        defer { freeifaddrs(list) }
        var interfaces: [String: (UInt64, UInt64)] = [:]
        var item = list
        while let pointer = item {
            let interface = pointer.pointee
            item = interface.ifa_next
            guard let address = interface.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces[name] = (UInt64(counters.ifi_ibytes), UInt64(counters.ifi_obytes))
        }
        // getifaddrs exposes legacy 32-bit byte totals; prefer the route table's 64-bit counters.
        for (name, counters) in wideNetworkCounters() where interfaces[name] != nil {
            interfaces[name] = counters
        }
        var primary: String?
        if let store {
            for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
                if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                   let name = value["PrimaryInterface"] as? String, interfaces[name] != nil {
                    primary = name; break
                }
            }
        }
        // Count one physical interface, not both physical traffic and its VPN tunnel.
        guard let name = primary ?? interfaces.keys.sorted().first,
              let counters = interfaces[name] else {
            result.networkName = "未连接"
            lastNetwork = nil
            return
        }
        result.networkConnected = true
        let type = interfaceTypes[name]
        let label = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? "Wi-Fi" : "以太网"
        result.networkName = "\(label) · \(name)"
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastNetwork, previous.name == name {
            result.download = StatsMath.rate(previous: previous.rx, current: counters.0, elapsed: now - previous.time)
            result.upload = StatsMath.rate(previous: previous.tx, current: counters.1, elapsed: now - previous.time)
        }
        lastNetwork = (name, counters.0, counters.1, now)
    }

    private func wideNetworkCounters() -> [String: (UInt64, UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<if_msghdr2>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&mib, UInt32(mib.count), buffer, &length, nil, 0) == 0 else { return [:] }
        var offset = 0
        var result: [String: (UInt64, UInt64)] = [:]
        while offset + 4 <= length {
            let message = buffer.advanced(by: offset)
            let size = Int(message.loadUnaligned(as: UInt16.self))
            guard size >= 4, offset + size <= length else { break }
            let type = message.load(fromByteOffset: 3, as: UInt8.self)
            if type == RTM_IFINFO2, size >= MemoryLayout<if_msghdr2>.size {
                let header = message.loadUnaligned(as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(header.ifm_index), &name) != nil {
                    result[String(cString: name)] = (header.ifm_data.ifi_ibytes, header.ifm_data.ifi_obytes)
                }
            }
            offset += size
        }
        return result
    }
}

final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    private let queue = DispatchQueue(label: "cn.nexastore.nexa.metrics", qos: .utility)
    private let sampler = MetricsSampler()
    private var timer: DispatchSourceTimer?
    private var history: [CPUPoint] = []
    private var generation = 0

    func start(interval: Double) {
        stop()
        let currentGeneration = generation
        queue.async { self.sampler.reset(); self.history.removeAll() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var next = self.sampler.sample()
            if let value = next.cpu { self.history.append(CPUPoint(time: Date(), value: value)) }
            self.history.removeAll { $0.time < Date().addingTimeInterval(-60) }
            next.history = self.history
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.snapshot = next
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
    }

    // Fixed sample readings for documentation screenshots, so they show no real machine.
    func showDemo() {
        stop()
        let now = Date()
        var demo = Snapshot()
        demo.cpu = 18; demo.userCPU = 12; demo.systemCPU = 6
        demo.memoryTotal = 16 * 1_073_741_824
        demo.memoryUsed = UInt64(9.6 * 1_073_741_824)
        demo.memoryPressure = 1
        demo.swapUsed = 0
        demo.diskTotal = 500_000_000_000
        demo.diskFree = 312_000_000_000
        demo.download = 1_840_000
        demo.upload = 236_000
        demo.networkName = "Wi-Fi · en0"
        demo.networkConnected = true
        demo.sampledAt = now
        let curve: [Double] = [9, 10, 9, 11, 12, 10, 9, 13, 21, 34, 41, 36, 27, 19, 14, 12, 11, 13, 12, 10,
                               11, 14, 17, 15, 13, 12, 16, 22, 20, 18]
        demo.history = curve.enumerated().map { index, value in
            CPUPoint(time: now.addingTimeInterval(Double(index - curve.count + 1) * 2), value: value)
        }
        snapshot = demo
    }
}
