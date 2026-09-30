import SwiftUI
import SwiftData

@main
struct TravelNotesApp: App {
    #if targetEnvironment(macCatalyst)
    private static let catalystContainer = try! ModelContainer(
        for: Schema([TicketEntry.self, MailCandidate.self]),
        configurations: [ModelConfiguration(url: AppData.storeURL!)])
    #endif

    @State private var tabSelection: Int = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-SyncTab") { return 5 }
        if args.contains("-FootprintTab") { return 4 }
        if args.contains("-StatsTab") { return 3 }
        if args.contains("-TripTab") { return 2 }
        if args.contains("-HomeTab") { return 1 }
        if args.contains("-BoardTab") { return 0 }
        return 0
    }()

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst)
            // SwiftUI 的 TabView 在 Mac 上渲染成工具栏下拉菜单(.tabBarOnly 也只作用于工具栏),
            // 故 Mac 用自绘底部标签栏,与手机一致
            MacTabRoot(selection: $tabSelection)
                .modifier(AutoSyncOnActive())
                .modelContainer(Self.catalystContainer)
                .task { SnapshotSupport.runIfNeeded() }
                .task { await MailSyncEngine.runSelfTestIfNeeded() }
                .task { TripCalendar.runSelfTestIfNeeded() }
                .task { TicketMailParser.runSelfTestIfNeeded() }
            #else
            TabView(selection: $tabSelection) {
                BoardView()
                    .tag(0)
                    .tabItem { Label("大屏", systemImage: "list.bullet.rectangle.portrait.fill") }
                HomeView()
                    .tag(1)
                    .tabItem { Label("票根", systemImage: "ticket") }
                TripView()
                    .tag(2)
                    .tabItem { Label("行程", systemImage: "flag.checkered") }
                StatsView()
                    .tag(3)
                    .tabItem { Label("统计", systemImage: "chart.bar.fill") }
                FootprintView()
                    .tag(4)
                    .tabItem { Label("足迹", systemImage: "map") }
                SyncView()
                    .tag(5)
                    .tabItem { Label("同步", systemImage: "envelope.arrow.triangle.branch") }
            }
            .modifier(AutoSyncOnActive())
            .modelContainer(for: [TicketEntry.self, MailCandidate.self])
            .task { SnapshotSupport.runIfNeeded() }
            .task { await MailSyncEngine.runSelfTestIfNeeded() }
            .task { TripCalendar.runSelfTestIfNeeded() }
            .task { TicketMailParser.runSelfTestIfNeeded() }
            #endif
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Mac 版根视图:六页常驻(透明度切换,保留各页滚动位置/输入状态),底部自绘标签栏
private struct MacTabRoot: View {
    @Binding var selection: Int

    private let tabs: [(label: String, icon: String)] = [
        ("大屏", "list.bullet.rectangle.portrait.fill"),
        ("票根", "ticket"),
        ("行程", "flag.checkered"),
        ("统计", "chart.bar.fill"),
        ("足迹", "map"),
        ("同步", "envelope.arrow.triangle.branch")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                BoardView()
                    .opacity(selection == 0 ? 1 : 0)
                    .allowsHitTesting(selection == 0)
                HomeView()
                    .opacity(selection == 1 ? 1 : 0)
                    .allowsHitTesting(selection == 1)
                TripView()
                    .opacity(selection == 2 ? 1 : 0)
                    .allowsHitTesting(selection == 2)
                StatsView()
                    .opacity(selection == 3 ? 1 : 0)
                    .allowsHitTesting(selection == 3)
                FootprintView()
                    .opacity(selection == 4 ? 1 : 0)
                    .allowsHitTesting(selection == 4)
                SyncView()
                    .opacity(selection == 5 ? 1 : 0)
                    .allowsHitTesting(selection == 5)
            }
            tabBar
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tabs[i].icon)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                        Text(tabs[i].label)
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .foregroundStyle(selection == i ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tabs[i].label)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
#endif

/// 回到前台时自动增量同步
struct AutoSyncOnActive: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { trigger() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { trigger() }
            }
            .task { await TripNotifications.refresh(context: modelContext) }
    }

    private func trigger() {
        // 调试钩子:-MailUser/-MailPass/-MailOwner 预置账号后自动同步
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MailUser"), i + 1 < args.count,
           let j = args.firstIndex(of: "-MailPass"), j + 1 < args.count {
            MailSyncEngine.shared.saveAccount(email: args[i + 1], authCode: args[j + 1])
        }
        if let k = args.firstIndex(of: "-MailOwner"), k + 1 < args.count {
            UserDefaults.standard.set(args[k + 1], forKey: "mail.owner")
        }
        MailSyncEngine.shared.autoSyncIfNeeded(context: modelContext)
        // 回前台重排行程通知(编辑/同步后保持最新)
        Task { await TripNotifications.refresh(context: modelContext) }
    }
}
