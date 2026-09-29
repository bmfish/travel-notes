import SwiftUI
import SwiftData

@main
struct TravelNotesApp: App {
    @State private var tabSelection: Int = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-SyncTab") { return 5 }
        if args.contains("-FootprintTab") { return 4 }
        if args.contains("-StatsTab") { return 3 }
        if args.contains("-TripTab") { return 2 }
        if args.contains("-BoardTab") { return 0 }
        return 0
    }()

    var body: some Scene {
        WindowGroup {
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
        }
    }
}

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
    }
}
