import SwiftUI
import AppKit

final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage] = [:]
    func icon(for app: AppIdentity) -> NSImage {
        if let image = icons[app.path] { return image }
        let image = app.path.isEmpty
            ? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            : NSWorkspace.shared.icon(forFile: app.path)
        icons[app.path] = image
        return image
    }
}

final class ActivitySelection: ObservableObject {
    @Published var search = ""
    @Published var sort = ActivitySort.cpu
}

struct ActivityView: View {
    @ObservedObject var activity: AppActivityMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var selection: ActivitySelection
    private var rows: [AppResource] {
        ActivityQuery.rows(apps: activity.apps, search: selection.search, sort: selection.sort)
    }

    var body: some View {
        VStack(spacing: u(0)) {
            HStack(spacing: u(5)) {
                FeatherView().frame(width: u(13), height: u(13))
                Text("nexa.").font(Brand.display(14, .heavy)).tracking(-0.6)
                Spacer()
            }.padding(.horizontal, u(24)).padding(.top, u(30))
            HStack(alignment: .lastTextBaseline) {
                (Text("应用活动").foregroundColor(Brand.ink) + Text(".").foregroundColor(Brand.accent))
                    .font(.system(size: u(26), weight: .medium)).tracking(-0.8)
                Spacer()
                Text("当前用户正在运行的应用，按整机比例计算 CPU。").font(.system(size: u(10))).foregroundStyle(Brand.muted)
            }.padding(.horizontal, u(24)).padding(.top, u(14)).padding(.bottom, u(14))
            Hairline().padding(.horizontal, u(24))
            HStack(spacing: u(6)) {
                ForEach(ActivitySort.allCases, id: \.self) { key in chip(key) }
                Spacer(minLength: u(12))
                HStack(spacing: u(7)) {
                    Image(systemName: "magnifyingglass").font(.system(size: u(11))).foregroundStyle(Brand.muted)
                    TextField("应用名称或 PID", text: $selection.search).textFieldStyle(.plain).font(.system(size: u(11)))
                    if !selection.search.isEmpty {
                        Button { selection.search = "" } label: {
                            Image(systemName: "xmark").font(.system(size: u(8), weight: .bold)).foregroundStyle(Brand.muted)
                                .frame(width: u(16), height: u(16)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, u(10)).frame(width: u(190), height: u(30))
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: u(5), style: .continuous))
            }.padding(.horizontal, u(24)).padding(.vertical, u(12))
            Hairline().padding(.horizontal, u(24))
            HStack {
                Text(selection.search.isEmpty ? "全部应用" : "搜索结果").font(.system(size: u(10), weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: u(10))).foregroundStyle(Brand.muted).monospacedDigit()
            }.padding(.horizontal, u(24)).padding(.top, u(12)).padding(.bottom, u(8))
            Hairline().padding(.horizontal, u(24))
            if rows.isEmpty {
                VStack(spacing: u(8)) {
                    Text(emptyTitle).font(.system(size: u(13), weight: .medium))
                    if !selection.search.isEmpty {
                        Text("换一个名称或 PID 试试。").font(.system(size: u(11))).foregroundStyle(Brand.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(u(24))
            } else {
                ScrollView {
                    LazyVStack(spacing: u(0)) {
                        // Bars compare apps with each other; the number beside each one is the absolute share.
                        let scale = max(5, activity.busiest?.cpu ?? 0)
                        ForEach(rows) { row in
                            appRow(row, scale: scale).padding(.horizontal, u(24))
                            Hairline().padding(.horizontal, u(24))
                        }
                    }
                }
            }
            HStack(spacing: u(6)) {
                Text("Nexa").font(Brand.display(11, .bold))
                Spacer()
                Circle().fill(activity.sampledAt == nil ? Brand.muted : Brand.good).frame(width: u(5), height: u(5))
                Text(activity.sampledAt == nil ? "正在读取" : "实时 · 每 2 秒刷新 · 不保存记录")
            }.font(.system(size: u(10))).foregroundStyle(Brand.muted).padding(.horizontal, u(24)).padding(.vertical, u(12))
        }
        .frame(minWidth: u(520), idealWidth: u(560), maxWidth: .infinity,
               minHeight: u(380), idealHeight: u(480), maxHeight: .infinity)
        .background(Brand.paper)
        .foregroundStyle(Brand.ink).tint(Brand.accent)
        .preferredColorScheme(preferences.appearance == "system" ? nil : (preferences.appearance == "dark" ? .dark : .light))
    }

    private var summary: String {
        guard activity.sampledAt != nil else { return "正在读取" }
        let bytes = activity.apps.compactMap(\.memory).reduce(0, +)
        let memory = bytes >= 1_073_741_824 ? "\(Units.memory(bytes)) GB" : "\(Int(Double(bytes) / 1_048_576)) MB"
        return "\(rows.count) 个应用 · 共占用 \(memory)"
    }

    // The catalogue's filter chips: the chosen one is solid ink.
    private func chip(_ key: ActivitySort) -> some View {
        let active = selection.sort == key
        return Button { selection.sort = key } label: {
            HStack(spacing: u(5)) {
                Text("按\(key.rawValue)").font(.system(size: u(11), weight: active ? .medium : .regular))
                if active {
                    Image(systemName: key == .name ? "arrow.up" : "arrow.down").font(.system(size: u(7), weight: .bold))
                        .foregroundStyle(Color(red: 23 / 255, green: 23 / 255, blue: 21 / 255))
                        .frame(width: u(14), height: u(14))
                        .background(Brand.accent, in: RoundedRectangle(cornerRadius: u(2), style: .continuous))
                }
            }
            .foregroundStyle(active ? Brand.onInk : Brand.body)
            .padding(.leading, u(11)).padding(.trailing, active ? u(7) : u(11)).frame(height: u(30))
            .background(active ? Brand.ink : Color.clear, in: RoundedRectangle(cornerRadius: u(4), style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("按\(key.rawValue)排序")
    }

    private func appRow(_ row: AppResource, scale: Double) -> some View {
        HStack(spacing: u(12)) {
            HStack(spacing: u(11)) {
                Image(nsImage: AppIconCache.shared.icon(for: row.app)).resizable().frame(width: u(26), height: u(26))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: u(3)) {
                    HStack(spacing: u(6)) {
                        Text(row.app.name).font(.system(size: u(12), weight: .medium)).lineLimit(1)
                        if activity.foreground == row.id { AccentTag("前台") }
                    }
                    Text("\(row.processCount) 个进程" + (row.partial ? " · 部分数据" : ""))
                        .font(.system(size: u(10))).foregroundStyle(Brand.muted).lineLimit(1)
                }
                Spacer(minLength: u(0))
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: u(10)) {
                Gauge(fraction: row.cpu.map { min(1, $0 / scale) }, level: 0, accent: true)
                    .frame(width: u(64), height: u(12)).accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: u(1)) {
                    Text(row.cpu.map { String(format: "%.1f", $0) } ?? "—").font(Brand.display(14)).tracking(-0.3)
                    Text("%").font(Brand.display(9)).foregroundStyle(Brand.muted)
                }.frame(width: u(52), alignment: .trailing)
            }.frame(width: u(130), alignment: .trailing)
            memory(row.memory).frame(width: u(78), alignment: .trailing)
        }
        .monospacedDigit().frame(height: u(50))
        .contentShape(Rectangle())
        .help("\(row.app.id)\n\(row.app.path)\n主进程 PID：\(row.pid)\nCPU 为整机比例；内存为可读取进程的物理占用总和。")
        .contextMenu {
            Button("切换到此应用") { NSRunningApplication(processIdentifier: row.pid)?.activate(options: []) }
            if !row.app.path.isEmpty {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.app.path)])
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func memory(_ bytes: UInt64?) -> some View {
        let parts: (String, String) = bytes.map {
            $0 >= 1_073_741_824 ? (Units.memory($0), "GB") : ("\(Int(Double($0) / 1_048_576))", "MB")
        } ?? ("—", "")
        return HStack(alignment: .firstTextBaseline, spacing: u(2)) {
            Text(parts.0).font(Brand.display(14)).tracking(-0.3)
            Text(parts.1).font(Brand.display(9)).foregroundStyle(Brand.muted)
        }
    }
    private var emptyTitle: String {
        if !selection.search.isEmpty { return "没有匹配的应用" }
        return activity.sampledAt == nil ? "正在读取应用…" : "没有可读取的用户应用"
    }
}
