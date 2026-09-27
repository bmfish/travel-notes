import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TicketEntry.date, order: .reverse) private var entries: [TicketEntry]

    @State private var showingAdd = false
    @State private var entryToEdit: TicketEntry?
    @State private var entryToDelete: TicketEntry?

    private var grouped: [(year: Int, items: [TicketEntry])] {
        Dictionary(grouping: entries) { Calendar.current.component(.year, from: $0.date) }
            .map { (year: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.year > $1.year }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Theme.paperBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        header
                        if entries.isEmpty {
                            EmptyStateView { showingAdd = true }
                        } else {
                            timeline
                        }
                        Spacer(minLength: 110)
                    }
                }

                addButton
            }
            .navigationDestination(for: UUID.self) { id in
                if let entry = entries.first(where: { $0.id == id }) {
                    DetailView(entry: entry)
                }
            }
            .sheet(isPresented: $showingAdd) { AddEditView() }
            .sheet(item: $entryToEdit) { entry in AddEditView(entry: entry) }
            .confirmationDialog(
                "删除这张票根?",
                isPresented: Binding(
                    get: { entryToDelete != nil },
                    set: { if !$0 { entryToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let e = entryToDelete {
                        PhotoStore.delete(e.photoFileNames)
                        modelContext.delete(e)
                    }
                    entryToDelete = nil
                }
                Button("取消", role: .cancel) { entryToDelete = nil }
            } message: {
                Text("日记和照片会一并删除,无法恢复。")
            }
            .task {
                seedIfNeeded()
                // 调试钩子:-ImportAll 启动时批量导入全部候选
                if ProcessInfo.processInfo.arguments.contains("-ImportAll") {
                    let count = MailSyncEngine.importAllCandidates(context: modelContext)
                    MailSyncEngine.trace("importAll: \(count)")
                }
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("🚄").font(.system(size: 26))
                Text("我的火车票日记")
                    .font(.system(size: 25, weight: .heavy, design: .serif))
                    .foregroundColor(Theme.ticketInk)
            }
            Text(statsText)
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketGray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var timeline: some View {
        LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
            ForEach(grouped, id: \.year) { group in
                Section {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(value: entry.id) {
                            MiniTicketCard(
                                info: TicketInfo(entry: entry),
                                tilt: index % 2 == 0 ? -1.3 : 1.4
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                entryToEdit = entry
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                entryToDelete = entry
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    YearHeader(year: group.year)
                }
            }
        }
        .padding(.horizontal, 18)
    }

    private var addButton: some View {
        Button {
            showingAdd = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [Theme.railRed, Theme.railRedDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                )
                .shadow(color: Theme.railRed.opacity(0.4), radius: 8, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    // MARK: 数据

    private var uniqueStations: Set<String> {
        var set = Set<String>()
        for e in entries {
            if let f = e.fromStation, !f.isEmpty { set.insert(f) }
            if let t = e.toStation, !t.isEmpty { set.insert(t) }
        }
        return set
    }

    private var statsText: String {
        var parts = ["已收集 \(entries.count) 张票根", "途经 \(uniqueStations.count) 站"]
        let km = Int(MileageEstimator.totalKm(entries: entries))
        if km > 0 { parts.append("里程约 \(km) km") }
        return parts.joined(separator: " · ")
    }

    /// 模拟器演示数据:启动参数带 -UITestSeed 时注入
    private func seedIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-UITestSeed"), entries.isEmpty else { return }
        for e in SampleData.make() { modelContext.insert(e) }
        try? modelContext.save()
    }
}

private struct YearHeader: View {
    let year: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(String(year)) 年")
                .font(.system(size: 14, weight: .heavy, design: .serif))
                .foregroundColor(Theme.railRedDeep)
            Rectangle()
                .fill(Theme.railRedDeep.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .background(Theme.paperBackground)
    }
}

private struct EmptyStateView: View {
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.ticketGray.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .frame(width: 250, height: 112)
                VStack(spacing: 6) {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 30))
                        .foregroundColor(Theme.ticketGray.opacity(0.6))
                    Text("这里还没有票根")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ticketGray)
                }
            }
            Button(action: onAdd) {
                Text("记下你的第一张车票 ✍️")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.railRedDeep)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
