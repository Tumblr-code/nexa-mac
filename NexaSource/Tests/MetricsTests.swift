import Foundation
import Darwin

@main
enum MetricsTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        passed += 1
        print("PASS: \(message)")
    }

    static func main() {
        let usage = StatsMath.cpu(previous: [100, 100, 100, 0], current: [116, 108, 176, 0])!
        check(abs(usage.0 - 24) < 0.001, "CPU total delta")
        check(abs(usage.1 - 16) < 0.001, "CPU user delta")
        check(abs(usage.2 - 8) < 0.001, "CPU system delta")
        check(StatsMath.cpu(previous: [0, 0, 0, 0], current: [0, 0, 0, 0]) == nil, "No ticks is unavailable")
        check(StatsMath.cpu(previous: [], current: []) == nil, "Malformed tick arrays")
        let wrapped = StatsMath.cpu(previous: [UInt32.max - 5, 0, 0, 0], current: [4, 0, 10, 0])!
        check(abs(wrapped.0 - 50) < 0.001, "CPU counter wrap")
        check(StatsMath.rate(previous: 100, current: 500, elapsed: 2) == 200, "Network rate")
        check(StatsMath.rate(previous: 500, current: 100, elapsed: 2) == nil, "Interface reset")
        check(StatsMath.rate(previous: 100, current: 100, elapsed: 2) == 0, "Idle network")
        check(StatsMath.rate(previous: 0, current: 100, elapsed: 0) == nil, "Zero interval")
        check(StatsMath.rate(previous: 0, current: 100, elapsed: .nan) == nil, "Invalid interval")
        check(StatsMath.memory(internalPages: 100, purgeable: 20, wired: 10, compressed: 5, pageSize: 16, total: 5000) == 1520, "Memory accounting")
        check(StatsMath.memory(internalPages: 10, purgeable: 20, wired: 10, compressed: 5, pageSize: 16, total: 5000) == 240, "Purgeable underflow")
        check(StatsMath.memory(internalPages: 1000, purgeable: 0, wired: 10, compressed: 5, pageSize: 16, total: 5000) == 5000, "Memory total clamp")
        check(Units.speed(nil).0 == "—", "Unavailable speed")
        check(Units.speed(.infinity).0 == "—", "Invalid speed")
        check(Units.speed(2_400_000).0 == "2.4" && Units.speed(2_400_000).1 == "MB/s", "Speed units")
        check(Units.memory(51_539_607_552) == "48.0", "48 GB hardware memory")
        check(Units.disk(512_000_000_000) == "512", "Decimal disk units")

        let trend = TrendMath.points([(age: 0, value: 50), (age: 30, value: 150), (age: 60, value: -5),
                                      (age: 61, value: 10), (age: -1, value: 10), (age: 10, value: .nan)], window: 60)
        check(trend.count == 3, "Trend drops stale, future and invalid samples")
        check(trend.map(\.x) == [0, 0.5, 1], "Trend orders samples oldest first by age")
        check(trend.map(\.y) == [0, 1, 0.5], "Trend clamps values to the plot")
        check(TrendMath.points([(age: 0, value: 1)], window: 0).isEmpty, "Trend needs a valid window")
        check(TrendMath.ceiling(peak: nil) == 25 && TrendMath.ceiling(peak: 8) == 25, "Trend scale has a 25% floor")
        check(TrendMath.ceiling(peak: 26) == 50 && TrendMath.ceiling(peak: 100) == 100 && TrendMath.ceiling(peak: 400) == 100, "Trend scale steps up with the peak")
        check(TrendMath.points([(age: 0, value: 10)], window: 60, ceiling: 25).first?.y == 0.4, "Trend plots against its scale")
        check(TrendMath.fraction(12, of: 48) == 0.25 && TrendMath.fraction(60, of: 48) == 1, "Gauge fraction")
        check(TrendMath.fraction(nil, of: 48) == nil && TrendMath.fraction(1, of: 0) == nil, "Gauge unavailable")
        var plotted = Snapshot()
        plotted.sampledAt = Date()
        plotted.history = [CPUPoint(time: plotted.sampledAt!.addingTimeInterval(-90), value: 80),
                           CPUPoint(time: plotted.sampledAt!.addingTimeInterval(-15), value: 20)]
        check(plotted.trend.count == 1 && abs(plotted.trend[0].x - 0.75) < 0.001, "Snapshot trend uses the last 60 seconds")
        plotted.history.append(CPUPoint(time: plotted.sampledAt!.addingTimeInterval(0.01), value: 30))
        check(plotted.trend.count == 2 && plotted.trend.last?.x == 1, "Newest sample is kept when stamped after the snapshot")
        plotted.diskTotal = 500; plotted.diskFree = 125
        check(plotted.diskFraction == 0.75, "Disk gauge shows used share")

        let sampler = MetricsSampler()
        let first = sampler.sample()
        check(first.cpu == nil, "First sample has no fabricated CPU rate")
        check(first.download == nil, "First sample has no fabricated network rate")
        Thread.sleep(forTimeInterval: 0.2)
        let second = sampler.sample()
        check(second.cpu != nil && (0...100).contains(second.cpu!), "Live CPU bounds")
        check(second.memoryUsed != nil && second.memoryUsed! <= second.memoryTotal, "Live memory bounds")
        check(second.diskFree != nil && second.diskTotal != nil && second.diskFree! <= second.diskTotal!, "Live disk bounds")
        sampler.reset()
        check(sampler.sample().cpu == nil, "Wake or refresh reset discards stale counters")
        print("\(passed) tests passed.")
    }
}
