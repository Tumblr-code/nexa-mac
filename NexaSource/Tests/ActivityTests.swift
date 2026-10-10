import AppKit
import Foundation

@main
enum ActivityTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        passed += 1
        print("PASS: \(message)")
    }
    static func main() {
        let app = AppIdentity(id: "test.editor", name: "Editor", path: "/Applications/Editor.app")
        let browser = AppIdentity(id: "test.browser", name: "Browser", path: "/Applications/Browser.app")

        let root = RunningApp(identity: app, pid: 10)
        let main = ProcessReading(pid: 10, parent: 1, path: app.path + "/Contents/MacOS/main", started: 1, cpu: 1, memory: 1)
        let helper = ProcessReading(pid: 11, parent: 1, path: app.path + "/Contents/Frameworks/Helper.app/Contents/MacOS/helper", started: 1, cpu: 1, memory: 1)
        let child = ProcessReading(pid: 12, parent: 10, path: "/usr/bin/tool", started: 1, cpu: 1, memory: 1)
        let unrelated = ProcessReading(pid: 13, parent: 1, path: app.path + "-other/Contents/MacOS/main", started: 1, cpu: 1, memory: 1)
        let all: [pid_t: ProcessReading] = [10: main, 11: helper, 12: child, 13: unrelated]
        check(ActivityMath.owner(main, roots: [root], processes: all) == app.id, "Main PID ownership")
        check(ActivityMath.owner(helper, roots: [root], processes: all) == app.id, "Nested helper grouping")
        check(ActivityMath.owner(child, roots: [root], processes: all) == app.id, "Subprocess ancestry grouping")
        check(ActivityMath.owner(unrelated, roots: [root], processes: all) == nil, "Reject ambiguous path prefix")
        let nested = RunningApp(identity: AppIdentity(id: "test.editor.helper", name: "Helper",
            path: app.path + "/Contents/Frameworks/Helper.app"), pid: 11)
        let sibling = RunningApp(identity: AppIdentity(id: "test.editor.other", name: "Other", path: app.path + "-other"), pid: 13)
        check(ActivityMath.topLevel([nested, root, sibling]).map(\.pid) == [10, 13], "Bundled helper app folds into its parent")
        check(ActivityMath.owner(helper, roots: ActivityMath.topLevel([nested, root]), processes: all) == app.id, "Folded helper's process counts for the parent")
        let cycle = ProcessReading(pid: 20, parent: 20, path: "/tmp/other", started: 1, cpu: nil, memory: nil)
        check(ActivityMath.owner(cycle, roots: [root], processes: [20: cycle]) == nil, "Cycle-safe ancestry")
        check(ActivityMath.cpu(previous: 0, current: 1_000_000_000, elapsed: 1, cores: 10) == 10, "CPU normalized to machine")
        check(ActivityMath.cpu(previous: 100, current: 0, elapsed: 1, cores: 10) == nil, "CPU counter reset")
        check(ActivityMath.cpu(previous: 0, current: 100, elapsed: 0, cores: 10) == nil, "CPU baseline unavailable")
        check(ActivityMath.nanoseconds(ticks: 24_000_000, numer: 125, denom: 3) == 1_000_000_000, "Mach ticks convert to nanoseconds")
        check(ActivityMath.nanoseconds(ticks: 5, numer: 1, denom: 1) == 5, "Nanosecond timebase is unchanged")
        check(ActivityMath.nanoseconds(ticks: .max, numer: 125, denom: 3) == .max, "Tick conversion saturates instead of overflowing")

        let a = AppResource(app: app, cpu: 20, memory: 100, processCount: 2, partial: false, pid: 10)
        let b = AppResource(app: browser, cpu: nil, memory: 200, processCount: 1, partial: true, pid: 20)
        check(ActivityQuery.rows(apps: [b, a], search: "", sort: .cpu).first?.id == app.id, "CPU sort with unavailable last")
        check(ActivityQuery.rows(apps: [a, b], search: "", sort: .memory).first?.id == browser.id, "Memory sort")
        check(ActivityQuery.rows(apps: [a, b], search: "", sort: .name).first?.id == browser.id, "Name sort")
        check(ActivityQuery.rows(apps: [a, b], search: "EDITOR", sort: .name).count == 1, "Case insensitive app search")
        check(ActivityQuery.rows(apps: [a, b], search: "20", sort: .name).first?.id == browser.id, "PID search")
        check(ActivityQuery.rows(apps: [a], search: "not-a-real-app", sort: .cpu).isEmpty, "No results state")

        let folder = FileManager.default.temporaryDirectory
        let sampler = AppResourceSampler()
        let own = RunningApp(identity: AppIdentity(id: "test.self", name: "Tests", path: folder.path), pid: getpid())
        let initial = sampler.sample(apps: [own])
        check(initial.first?.cpu == nil, "No fabricated first CPU rate")
        check(initial.first?.memory != nil, "Live process memory without administrator permissions")
        let burnUntil = ProcessInfo.processInfo.systemUptime + 0.4
        var spin = 0.0
        while ProcessInfo.processInfo.systemUptime < burnUntil { spin += 1 }
        let next = sampler.sample(apps: [own])
        check(next.first?.cpu != nil && (0...100).contains(next.first!.cpu!), "Live process CPU bounds")
        let oneCore = (next.first?.cpu ?? 0) * Double(ProcessInfo.processInfo.activeProcessorCount)
        check(spin > 0 && oneCore > 60 && oneCore < 140, "A busy thread reads as about one core")
        sampler.reset()
        check(sampler.sample(apps: [own]).first?.cpu == nil, "Resource baseline resets after window close")
        print("\(passed) activity tests passed.")
    }
}
