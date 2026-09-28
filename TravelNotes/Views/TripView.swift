import SwiftUI
import SwiftData

/// 「行程」页:未开始的旅程(今天及以后),按出发时间升序,带出发倒计时
struct TripView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TicketEntry.date, order: .forward) private var entries: [TicketEntry]

    @State private var showingAdd = false
    @State private var entryToDelete: TicketEntry?
    /// 当天行程的实时信息(检票口/晚点),按行程 id 索引
    @State private var liveInfos: [UUID: TrainLiveInfo] = [:]
    /// 到达时刻(HH:mm),从经停时刻表取,按行程 id 索引
    @State private var arriveTimes: [UUID: String] = [:]
    /// 站台(车站大屏提前几天就排出来),按行程 id 索引
    @State private var platforms: [UUID: String] = [:]

    private var upcoming: [TicketEntry] {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.date >= start }
    }

    /// (标题, 区间天数上限):今天 / 一周内 / 更远
    private var groups: [(title: String, items: [TicketEntry])] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        var today: [TicketEntry] = [], soon: [TicketEntry] = [], later: [TicketEntry] = []
        for e in upcoming {
            let days = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: e.date)).day ?? 0
            if days <= 0 { today.append(e) }
            else if days <= 7 { soon.append(e) }
            else { later.append(e) }
        }
        var result: [(String, [TicketEntry])] = []
        if !today.isEmpty { result.append(("今天出发", today)) }
        if !soon.isEmpty { result.append(("一周内", soon)) }
        if !later.isEmpty { result.append(("更远的行程", later)) }
        return result.map { ($0.0, $0.1) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Theme.paperBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        header
                        if upcoming.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 14) {
                                ForEach(groups, id: \.title) { group in
                                    VStack(alignment: .leading, spacing: 10) {
                                        groupHeader(group.title)
                                        ForEach(group.items) { entry in
                                            NavigationLink(value: entry.id) {
                                                UpcomingTripCard(entry: entry,
                                                                 liveInfo: liveInfos[entry.id],
                                                                 arriveTime: arriveTimes[entry.id],
                                                                 platform: platforms[entry.id])
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    entryToDelete = entry
                                                } label: {
                                                    Label("删除", systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                        Spacer(minLength: 110)
                    }
                }
                .refreshable { await loadInfo() }

                addButton
            }
            .navigationDestination(for: UUID.self) { id in
                if let entry = entries.first(where: { $0.id == id }) {
                    DetailView(entry: entry)
                }
            }
            .sheet(isPresented: $showingAdd) { AddEditView() }
            .confirmationDialog(
                "删除这个行程?",
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
                        try? modelContext.save()
                    }
                    entryToDelete = nil
                }
                Button("取消", role: .cancel) { entryToDelete = nil }
            }
        }
        .preferredColorScheme(.light)
        .task {
            // 调试钩子:-TripDemo 注入几个未来行程方便看效果
            if ProcessInfo.processInfo.arguments.contains("-TripDemo"), upcoming.isEmpty {
                let cal = Calendar.current
                let samples: [(Int, String, String, String, String, String, String, Double)] = [
                    (0, "G1914", "郑州东", "上海虹桥", "08:25", "07", "02F", 471),
                    (2, "G4098", "郑州东", "上海虹桥", "08:12", "03", "08A", 471),
                    (5, "G1824", "上海虹桥", "郑州东", "13:07", "07", "02F", 471),
                    (21, "K152", "郑州", "上海", "21:05", "12", "036", 130)
                ]
                for (days, train, from, to, time, coach, seat, price) in samples {
                    let date = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date()))!
                    let comps = time.split(separator: ":")
                    let depart = cal.date(bySettingHour: Int(comps[0]) ?? 0, minute: Int(comps[1]) ?? 0,
                                          second: 0, of: date)
                    let entry = TicketEntry(date: date, departTime: depart, trainNo: train,
                                            fromStation: from, toStation: to, coach: coach,
                                            seat: seat, seatClass: train.hasPrefix("K") ? "硬卧" : "二等座",
                                            price: price)
                    modelContext.insert(entry)
                }
                try? modelContext.save()
            }
            await loadInfo()
        }
    }

    /// 行程卡补充信息:到达时刻(经停时刻表)、站台(车站大屏,提前几天就有)、检票口/晚点(出行日当天 12306 才公布检票口)
    private func loadInfo() async {
        for entry in upcoming {
            guard let code = entry.trainNo, !code.isEmpty else { continue }
            if arriveTimes[entry.id] == nil, let to = entry.toStation,
               let stops = try? await TrainScheduleService.shared.stops(
                   trainNo: code, fromStation: entry.fromStation ?? "",
                   toStation: to, date: entry.date),
               let stop = stops.first(where: { TrainLiveService.looseMatch($0.stationName, to) }),
               stop.arriveTime != "----" {
                arriveTimes[entry.id] = Self.hhmm(stop.arriveTime)
            }
            if platforms[entry.id] == nil, let from = entry.fromStation,
               let pf = try? await TrainLiveService.shared.platform(trainCode: code, date: entry.date,
                                                                    station: from) {
                platforms[entry.id] = pf
            }
            if let info = try? await TrainLiveService.shared.live(trainCode: code, date: entry.date) {
                liveInfos[entry.id] = info
            }
        }
    }

    /// "13:22" 或 "1322" -> "13:22"
    private static func hhmm(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 4 else { return raw }
        return digits.prefix(2) + ":" + digits.suffix(2)
    }

    // MARK: 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("🗺").font(.system(size: 26))
                Text("行程")
                    .font(.system(size: 25, weight: .heavy, design: .serif))
                    .foregroundColor(Theme.ticketInk)
            }
            Text(upcoming.isEmpty
                 ? "没有未开始的行程"
                 : "未开始的旅程 · 共 \(upcoming.count) 段")
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketGray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .heavy, design: .serif))
                .foregroundColor(Theme.railRedDeep)
            Rectangle()
                .fill(Theme.railRedDeep.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.ticketGray.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .frame(width: 250, height: 112)
                VStack(spacing: 6) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 30))
                        .foregroundColor(Theme.ticketGray.opacity(0.6))
                    Text("暂无未开始的行程")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ticketGray)
                }
            }
            Text("买了新车票?添加进来,出发前会在这里提醒你")
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketGray)
            Button(action: { showingAdd = true }) {
                Text("添加一个行程 ✍️")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.railRedDeep)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
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
}

// MARK: - 未开始行程卡片

private struct UpcomingTripCard: View {
    let entry: TicketEntry
    /// 当天行程的实时信息(检票口/晚点)
    let liveInfo: TrainLiveInfo?
    /// 到达时刻(HH:mm),来自经停时刻表
    let arriveTime: String?
    /// 站台(车站大屏,提前几天就有)
    let platform: String?

    private var color: Color { Theme.routeColor(from: entry.fromStation, to: entry.toStation) }

    private var isToday: Bool { Calendar.current.isDateInToday(entry.date) }

    private var gateText: String? {
        liveInfo?.stop(at: entry.fromStation)?.gateDisplay
    }

    private var gateChipText: String {
        if let gateText { return gateText }
        // 12306 出发当天才公布检票口(站台提前几天就有),未到出发日说明白,别显示成像 bug
        if isToday { return liveInfo == nil ? "查询中…" : "待公布" }
        return "出发当天公布"
    }

    private var countdownText: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: entry.date)).day ?? 0
        switch days {
        case ...0: return "今天出发"
        case 1: return "明天出发"
        default: return "还有 \(days) 天"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let trainNo = entry.trainNo, !trainNo.isEmpty {
                    Text(trainNo)
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(color))
                }
                Text(Fmt.cnDate.string(from: entry.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.ticketInk.opacity(0.75))
                if let depart = entry.departTime {
                    Text(Fmt.clock.string(from: depart) + " 开"
                         + (arriveTime.map { " · \($0) 到" } ?? ""))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.ticketInk.opacity(0.75))
                }
                Spacer()
                Text(countdownText)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.14)))
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("出发")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.ticketGray)
                    Text(TicketInfo.stationText(entry.fromStation))
                        .font(.system(size: 19, weight: .heavy, design: .serif))
                        .foregroundColor(Theme.ticketInk)
                }
                VStack(spacing: 2) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(color)
                    Text(entry.trainNo ?? "")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ticketGray)
                }
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("到达")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.ticketGray)
                    Text(TicketInfo.stationText(entry.toStation))
                        .font(.system(size: 19, weight: .heavy, design: .serif))
                        .foregroundColor(Theme.ticketInk)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if let coach = entry.coach, !coach.isEmpty {
                    infoChip("\(coach)车")
                }
                if let seat = entry.seat, !seat.isEmpty {
                    infoChip(seat)
                }
                if let seatClass = entry.seatClass, !seatClass.isEmpty {
                    infoChip(seatClass)
                }
                if let price = entry.price, price > 0 {
                    Text(price.truncatingRemainder(dividingBy: 1) == 0
                         ? String(format: "¥%.0f", price) : String(format: "¥%.1f", price))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                liveChip(icon: "door.left.hand.open",
                         text: "检票口 \(gateChipText)",
                         tint: gateText == nil ? Theme.ticketGray : Theme.railBlue)
                if let platform {
                    liveChip(icon: "square.stack.3d.up",
                             text: "站台 \(platform)",
                             tint: Theme.railBlueDeep)
                }
                if isToday {
                    if let liveInfo {
                        let delay = liveInfo.maxDelay
                        liveChip(icon: delay > 0 ? "clock.badge.exclamationmark" : "checkmark.circle",
                                 text: delay > 0 ? "晚点 \(delay) 分" : "正点",
                                 tint: delay > 0 ? Theme.railRed : Theme.routeGreen)
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white)
                .shadow(color: color.opacity(0.18), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .fill(color)
                .frame(width: 4),
            alignment: .leading
        )
    }

    private func infoChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.ticketInk.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ticketInk.opacity(0.06)))
    }

    private func liveChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}
