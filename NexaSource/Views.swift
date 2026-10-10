import SwiftUI
import AppKit
import ServiceManagement

struct NexaPanel: View {
    static var width: CGFloat { u(320) }
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var activity: AppActivityMonitor
    @State private var settings = false
    let chip: String
    var resize: () -> Void = {}
    private var data: Snapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: u(0)) {
            header
            if settings { preferencesView } else { metrics }
            footer
        }
        .frame(width: Self.width)
        .background(Brand.paper)
        .foregroundStyle(Brand.ink)
        .tint(Brand.accent)
        .preferredColorScheme(preferences.appearance == "system" ? nil : (preferences.appearance == "dark" ? .dark : .light))
        .onChange(of: settings) { resize() }
        .onChange(of: preferences.compact) { resize() }
        .onChange(of: preferences.scale) { resize() }
        .onReceive(NotificationCenter.default.publisher(for: .nexaShowSettings)) { _ in settings = true }
    }

    private var header: some View {
        HStack(spacing: u(6)) {
            FeatherView().frame(width: u(17), height: u(17))
            Text("nexa.").font(Brand.display(20, .heavy)).tracking(-0.9)
            Spacer()
            Circle().fill(data.warning ? Brand.caution : (data.cpu == nil ? Brand.muted : Brand.good))
                .frame(width: u(5), height: u(5))
            Text(settings ? "偏好设置" : data.status).font(.system(size: u(10))).foregroundStyle(Brand.muted)
        }.padding(.horizontal, u(18)).padding(.top, u(16)).padding(.bottom, u(14))
    }

    private var metrics: some View {
        VStack(spacing: u(0)) {
            hero.padding(.bottom, u(6))
            row("内存", detail: "共 \(Int(Double(data.memoryTotal) / Units.gib)) GB · 压力\(data.pressureText)",
                value: Units.memory(data.memoryUsed), unit: "GB",
                gauge: Gauge(fraction: data.memoryFraction, level: data.memoryPressure == 4 ? 2 : data.memoryPressure == 2 ? 1 : 0))
                .help("包含应用、联动和压缩内存，排除文件缓存。交换空间 \(Units.memory(data.swapUsed)) GB。")
            Hairline()
            network
            Hairline()
            row("磁盘", detail: "可用空间 · 共 \(Units.disk(data.diskTotal)) GB",
                value: Units.disk(data.diskFree), unit: "GB",
                gauge: Gauge(fraction: data.diskFraction,
                             level: (data.diskFraction ?? 0) > 0.95 ? 2 : (data.diskFraction ?? 0) > 0.85 ? 1 : 0))
                .help("当前用户所在 APFS 文件系统容量，不是硬盘标称容量。横条为已用比例。")
            Hairline()
            busiest
        }.padding(.horizontal, u(18))
    }

    // CPU sits on the site's product card: charcoal, small wordmark, accent tag, an accent block behind it.
    private var hero: some View {
        let compact = preferences.compact
        return ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: u(5), style: .continuous).fill(Brand.surface)
            Rectangle().fill(Brand.accent).frame(width: u(96), height: compact ? u(44) : u(60)).offset(y: compact ? u(6) : u(12))
            VStack(alignment: .leading, spacing: u(0)) {
                HStack {
                    Text("nexa.").font(Brand.display(10, .bold)).tracking(-0.3)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: u(8), weight: .semibold)).foregroundStyle(Brand.cardMuted)
                }
                Spacer(minLength: compact ? u(6) : u(10))
                HStack(alignment: .bottom, spacing: u(12)) {
                    HStack(alignment: .firstTextBaseline, spacing: u(2)) {
                        Text(data.cpu.map { String(format: "%.0f", $0) } ?? "—")
                            .font(Brand.display(compact ? 30 : 40, .medium)).tracking(-1.8).monospacedDigit()
                        Text("%").font(Brand.display(14, .medium)).foregroundStyle(Brand.cardMuted)
                    }.fixedSize()
                    Sparkline(points: data.trend, baseline: Brand.cardText.opacity(0.18), stroke: Brand.cardText)
                        .frame(height: compact ? u(22) : u(30)).padding(.bottom, compact ? u(6) : u(9)).accessibilityHidden(true)
                }
                Spacer(minLength: compact ? u(4) : u(8))
                HStack(alignment: .center) {
                    Text(compact ? "CPU" : "CPU · 系统 \(percent(data.systemCPU)) · 用户 \(percent(data.userCPU))")
                        .font(.system(size: u(10))).foregroundStyle(Brand.cardMuted).monospacedDigit().lineLimit(1)
                    Spacer()
                    AccentTag(chip.replacingOccurrences(of: "Apple ", with: ""))
                }
            }
            .padding(u(12)).foregroundStyle(Brand.cardText)
            .background { FrostedCard(glowHeight: compact ? u(44) : u(60), glowOffset: compact ? u(6) : u(12)) }
            .shadow(color: .black.opacity(0.22), radius: u(8), y: u(4))
            .padding(.leading, u(12)).padding(.trailing, u(24)).padding(.vertical, u(12))
        }
        .frame(height: compact ? u(122) : u(150))
        .help("最近 60 秒的 CPU 走势，峰值 \(percent(data.peakCPU))，纵轴上限 \(percent(data.trendCeiling))。")
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, detail: String, value: String, unit: String, gauge: Gauge) -> some View {
        HStack(spacing: u(10)) {
            VStack(alignment: .leading, spacing: u(3)) {
                Text(label).font(.system(size: u(12), weight: .medium))
                if !preferences.compact { Text(detail).font(.system(size: u(10))).foregroundStyle(Brand.muted).lineLimit(1) }
            }.layoutPriority(1)
            Spacer(minLength: u(6))
            gauge.frame(minWidth: u(24), maxWidth: u(56)).frame(height: u(12)).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: u(3)) {
                Text(value).font(Brand.display(17)).tracking(-0.5).monospacedDigit()
                Text(unit).font(Brand.display(9)).foregroundStyle(Brand.muted)
            }.fixedSize().frame(minWidth: u(64), alignment: .trailing)
        }.padding(.vertical, preferences.compact ? u(9) : u(10)).accessibilityElement(children: .combine)
    }

    private var network: some View {
        HStack(spacing: u(10)) {
            VStack(alignment: .leading, spacing: u(3)) {
                Text("网络").font(.system(size: u(12), weight: .medium))
                if !preferences.compact { Text(data.networkName).font(.system(size: u(10))).foregroundStyle(Brand.muted).lineLimit(1) }
            }.layoutPriority(1)
            Spacer(minLength: u(6))
            speed("arrow.down", data.download)
            speed("arrow.up", data.upload)
        }
        .padding(.vertical, preferences.compact ? u(9) : u(10))
        .help("下载 / 上传。按主物理接口计速，不重复统计 VPN。")
        .accessibilityElement(children: .combine)
    }

    private func speed(_ symbol: String, _ bytes: Double?) -> some View {
        let text = Units.speed(bytes)
        return HStack(alignment: .firstTextBaseline, spacing: u(3)) {
            Image(systemName: symbol).font(.system(size: u(8), weight: .bold)).foregroundStyle(Brand.accent)
            Text(text.0).font(Brand.display(13)).tracking(-0.3).monospacedDigit()
            Text(text.1).font(Brand.display(8)).foregroundStyle(Brand.muted)
        }.fixedSize().frame(minWidth: u(64), alignment: .trailing)
    }

    private var busiest: some View {
        Button { openActivityMonitor() } label: {
            HStack(spacing: u(10)) {
                if let top = activity.busiest {
                    Image(nsImage: AppIconCache.shared.icon(for: top.app)).resizable().frame(width: u(22), height: u(22))
                }
                VStack(alignment: .leading, spacing: u(3)) {
                    Text("占用最高").font(.system(size: u(10))).foregroundStyle(Brand.muted)
                    Text(activity.busiest?.app.name ?? "读取中…").font(.system(size: u(12), weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: u(6))
                HStack(alignment: .firstTextBaseline, spacing: u(2)) {
                    Text(activity.busiest?.cpu.map { String(format: "%.1f", $0) } ?? "—")
                        .font(Brand.display(17)).tracking(-0.5).monospacedDigit()
                    Text("%").font(Brand.display(9)).foregroundStyle(Brand.muted)
                }.fixedSize()
                RoundArrow()
            }.padding(.vertical, u(10)).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("当前占用 CPU 最多的应用，占整机全部核心的比例。点击查看全部应用。")
    }

    private var preferencesView: some View {
        VStack(alignment: .leading, spacing: u(0)) {
            Hairline()
            setting("菜单栏") {
                Picker("菜单栏", selection: $preferences.indicator) {
                    Text("仅羽毛").tag("icon")
                    Text("羽毛 + CPU").tag("cpu")
                    Text("羽毛 + 内存").tag("memory")
                }.labelsHidden().fixedSize()
            }
            setting("刷新间隔") {
                Picker("刷新间隔", selection: $preferences.interval) {
                    Text("2 秒").tag(2.0); Text("5 秒").tag(5.0); Text("10 秒").tag(10.0)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            setting("外观") {
                Picker("外观", selection: $preferences.appearance) {
                    Text("自动").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            setting("界面大小") {
                Picker("界面大小", selection: $preferences.scale) {
                    Text("标准").tag(1.0); Text("大").tag(1.2); Text("特大").tag(1.4)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            setting("精简指标说明") {
                Toggle("精简指标说明", isOn: $preferences.compact).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            setting("登录时启动") {
                Toggle("登录时启动", isOn: Binding(get: { preferences.loginEnabled },
                                               set: { preferences.setLogin($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if preferences.loginNeedsApproval {
                Button("前往系统设置允许登录启动") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link).font(.system(size: u(11))).padding(.bottom, u(10))
            }
            if let error = preferences.loginError {
                Text(error).font(.system(size: u(10))).foregroundStyle(Brand.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, u(10))
            }
            Hairline()
            HStack {
                Button { NSWorkspace.shared.open(URL(string: "https://nexastore.cn")!) } label: {
                    HStack(spacing: u(4)) {
                        Text("nexastore.cn").font(Brand.display(10, .semibold))
                        Image(systemName: "arrow.up.right").font(.system(size: u(8), weight: .bold))
                    }.foregroundStyle(Brand.accent).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                Eyebrow("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            }.padding(.vertical, u(12))
        }.padding(.horizontal, u(18))
    }

    private func setting<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: u(0)) {
            HStack {
                Text(label).font(.system(size: u(12)))
                Spacer()
                control()
            }.frame(height: u(40))
            Hairline().opacity(0.6)
        }
    }

    private var footer: some View {
        VStack(spacing: u(0)) {
            Hairline()
            HStack(spacing: u(14)) {
                Button("应用活动") { openActivityMonitor() }.buttonStyle(SplitButtonStyle())
                Spacer()
                Button { settings.toggle(); preferences.refreshLogin() } label: {
                    Text(settings ? "返回" : "设置").font(.system(size: u(11))).foregroundStyle(Brand.body)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: u(11), weight: .medium)).foregroundStyle(Brand.muted)
                        .frame(width: u(22), height: u(22)).contentShape(Rectangle())
                }.buttonStyle(.plain).help("退出 nexa").accessibilityLabel("退出 nexa")
            }.padding(.horizontal, u(18)).padding(.vertical, u(12))
        }
    }
    private func percent(_ number: Double?) -> String { number.map { String(format: "%.0f%%", $0) } ?? "—" }
}

extension Notification.Name {
    static let nexaShowSettings = Notification.Name("cn.nexastore.nexa.show-settings")
    static let nexaShowActivity = Notification.Name("cn.nexastore.nexa.show-activity")
}

func openActivityMonitor() {
    NotificationCenter.default.post(name: .nexaShowActivity, object: nil)
}

// Frosted charcoal glass: the accent block behind the card shows through as a soft glow,
// under a fine grain and a lit top edge.
struct FrostedCard: View {
    let glowHeight: CGFloat
    let glowOffset: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: u(10), style: .continuous)
        GeometryReader { proxy in
            // Where the accent block sits behind the card, diffused the way frosted glass would spread it.
            let centre = UnitPoint(x: 1.02, y: 0.5 + glowOffset / max(1, proxy.size.height))
            ZStack {
                Brand.card.opacity(0.94)
                EllipticalGradient(stops: [.init(color: Brand.accent.opacity(0.62), location: 0),
                                           .init(color: Brand.accent.opacity(0.26), location: 0.45),
                                           .init(color: Brand.accent.opacity(0), location: 1)],
                                   center: centre, startRadiusFraction: 0, endRadiusFraction: 0.5)
                LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(nsImage: Brand.grain).resizable(resizingMode: .tile).opacity(0.16).blendMode(.softLight)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.07)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct Sparkline: View {
    let points: [(x: Double, y: Double)]
    var baseline = Brand.line
    var stroke = Brand.accent

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let line = path(in: size)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: u(0), y: size.height - 0.5))
                    p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                }.stroke(baseline, lineWidth: 1)
                if points.count > 1, let first = points.first, let last = points.last {
                    Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: last.x * size.width, y: size.height))
                        p.addLine(to: CGPoint(x: first.x * size.width, y: size.height))
                        p.closeSubpath()
                    }.fill(LinearGradient(colors: [stroke.opacity(0.26), stroke.opacity(0)],
                                          startPoint: .top, endPoint: .bottom))
                    line.stroke(stroke, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
                if let last = points.last {
                    Circle().fill(Brand.accent).frame(width: u(4), height: u(4))
                        .position(x: min(size.width - 2, last.x * size.width), y: y(last.y, size.height))
                }
            }
        }
    }

    // Leaves room for the stroke so a 0% or 100% reading is not clipped.
    private func y(_ value: Double, _ height: CGFloat) -> CGFloat { 2 + (1 - value) * (height - 4) }
    private func path(in size: CGSize) -> Path {
        Path { p in
            for (index, point) in points.enumerated() {
                let target = CGPoint(x: point.x * size.width, y: y(point.y, size.height))
                if index == 0 { p.move(to: target) } else { p.addLine(to: target) }
            }
        }
    }
}

// A thin square-ended rule: ink for a normal reading, the status colours only when something needs attention.
struct Gauge: View {
    let fraction: Double?
    let level: Int
    var accent = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.line)
                if let fraction {
                    Rectangle().fill(level == 2 ? Brand.danger : level == 1 ? Brand.caution : accent ? Brand.accent : Brand.ink)
                        .frame(width: fraction > 0 ? max(2, proxy.size.width * fraction) : 0)
                }
            }.frame(height: u(2)).frame(maxHeight: .infinity)
        }
    }
}
