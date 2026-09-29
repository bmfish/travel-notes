import SwiftUI
import SwiftData

/// 「大屏」页:车站当日候车大屏(12306 小程序免登录接口)
/// 视觉沿用票根语言:每班车渲染成一张撕过的票根(左截时刻/站台,打孔虚线,右截车次/状态)
struct BoardView: View {
    @Query(sort: \TicketEntry.date, order: .reverse) private var entries: [TicketEntry]

    @State private var selectedStation = UserDefaults.standard.string(forKey: "board.station") ?? ""
    /// 0 出发 / 1 终到
    @State private var segment = 0
    /// 0 今天 / -1 昨天 / 1 明天
    @State private var dayOffset = 0
    /// 「···」展开的站名输入
    @State private var showStationInput = false
    @State private var stationQuery = ""
    @FocusState private var inputFocused: Bool

    /// 0 真实大屏(LED 暗板) / 1 票根样式
    @State private var displayMode = UserDefaults.standard.integer(forKey: "board.mode")
    /// 车次/车站模糊搜索
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// 已发车筛选:开着就完全不显示开走的车
    @State private var hideDeparted = UserDefaults.standard.object(forKey: "board.hideDeparted") as? Bool ?? true
    /// 点进去看经停时刻表的车
    @State private var routeTrain: BigScreenTrain?

    @State private var trains: [BigScreenTrain] = []
    /// 车次在大屏行 id -> 该站在本站的实时状态(检票口/检票状态/晚点),仅今天的临近车次
    @State private var liveByID: [String: TrainLiveStop] = [:]
    @State private var loading = false
    @State private var loaded = false
    @State private var lastUpdated: Date?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    heroCard
                    stationChips
                    controls
                    if selectedStation.isEmpty {
                        emptyPrompt
                    } else if let errorText {
                        Label(errorText, systemImage: "wifi.exclamationmark")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.ticketGray)
                            .padding(.top, 40)
                    } else if !loaded {
                        ProgressView().padding(.top, 60)
                    } else {
                        searchRow
                        if !query.isEmpty {
                            ledPanel(searchResults, searching: true)
                        } else if displayMode == 0 {
                            ledPanel(ledRows, searching: false)
                        } else if grouped.isEmpty {
                            Text(segment == 0 ? "当天暂无出发列车" : "当天暂无终到列车")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.ticketGray)
                                .padding(.top, 40)
                        } else {
                            ForEach(grouped, id: \.hour) { group in
                                VStack(spacing: 8) {
                                    hourHeader(group.hour)
                                    ForEach(group.trains) { train in
                                        Button { routeTrain = train } label: { stub(train) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .background(Theme.paperBackground.ignoresSafeArea())
            .refreshable { await load(force: true) }
            // 顶部大屏卡本身就是页头,隐藏导航栏避免重复标题
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $routeTrain) { train in
                TrainRouteView(train: train, station: selectedStation, day: boardDay)
            }
            .task(id: "\(selectedStation)|\(dayOffset)") {
                if selectedStation.isEmpty, let first = frequentStations.first {
                    pick(first)
                }
                await load()
                // 调试钩子:-BoardRoute 车次号,加载完自动推入该车时刻表,方便无头截图
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-BoardRoute"), i + 1 < args.count,
                   let train = trains.first(where: { $0.trainCode == args[i + 1].uppercased() }) {
                    routeTrain = train
                }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                guard loaded, !loading else { return }
                Task { await load() }
            }
        }
    }

    // MARK: 顶部大屏卡

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedStation.isEmpty ? "车站大屏" : selectedStation)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text(headerLine)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                Text(countLine)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clockText(ctx.date))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
                HStack(spacing: 4) {
                    Circle().fill(Theme.routeGreen).frame(width: 5, height: 5)
                    Text(lastUpdated.map { "刷新于 \(Self.clockText($0))" } ?? "实时刷新")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Theme.railBlueDeep, Theme.railBlue,
                                              Color(red: 0.16, green: 0.42, blue: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.railBlue.opacity(0.35), radius: 12, y: 6)
        )
    }

    private var headerLine: String {
        let cal = Calendar.current
        let week = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][cal.component(.weekday, from: boardDay) - 1]
        let m = cal.component(.month, from: boardDay)
        let d = cal.component(.day, from: boardDay)
        return "\(m)月\(d)日 · \(week)"
    }

    private var countLine: String {
        guard loaded, !trains.isEmpty else { return "等待加载" }
        let dep = trains.filter { !$0.terminating }.count
        let arr = trains.filter(\.terminating).count
        return "出发 \(dep) 班 · 终到 \(arr) 班"
    }

    private static func clockText(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: 车站选择

    /// 常用车站:按票根里出发/到达站出现次数,次数同则最近优先
    private var frequentStations: [String] {
        var count: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for e in entries {
            for s in [e.fromStation, e.toStation].compactMap(\.self) where !s.isEmpty {
                count[s, default: 0] += 1
                latest[s] = max(latest[s] ?? .distantPast, e.date)
            }
        }
        return count.sorted { a, b in
            a.value != b.value ? a.value > b.value : (latest[a.key] ?? .distantPast) > (latest[b.key] ?? .distantPast)
        }.map(\.key)
    }

    /// 芯片列表:当前选中的站置顶,再跟常用车站
    private var chips: [String] {
        var list = selectedStation.isEmpty ? [] : [selectedStation]
        list += frequentStations.prefix(6).filter { $0 != selectedStation }
        return list
    }

    /// 同城系列:每个常用车站所在城市的其他车站,如 上海虹桥 -> 上海/上海南/上海松江/上海西
    private var citySeries: [String] {
        var seen = Set(chips)
        var out: [String] = []
        for name in frequentStations.prefix(4) {
            guard let home = StationDirectory.shared.resolve(name) else { continue }
            for s in StationDirectory.shared.stations where s.c == home.c && !seen.contains(s.n) {
                out.append(s.n)
                seen.insert(s.n)
            }
        }
        return out
    }

    private var stationChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(chips + citySeries, id: \.self) { name in
                            chipLabel(name)
                        }
                        Color.clear.frame(width: 2)
                    }
                    .padding(.vertical, 2)
                }
                // 固定在行尾的「···」,点开输入车站
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showStationInput.toggle() }
                    if showStationInput {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inputFocused = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(showStationInput ? .white : Theme.railBlue)
                        .frame(width: 32, height: 28)
                        .background(Capsule().fill(showStationInput ? Theme.railBlue
                                                                    : Theme.creamPaper))
                }
            }
            if showStationInput {
                stationInput
            }
        }
    }

    private func chipLabel(_ name: String) -> some View {
        Button { pick(name) } label: {
            Text(name)
                .font(.system(size: 13, weight: name == selectedStation ? .bold : .regular))
                .foregroundColor(name == selectedStation ? .white : Theme.ticketInk)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(name == selectedStation ? Theme.railBlue
                                                                   : Theme.creamPaper))
        }
    }

    /// 与新增票根一致的站名输入:输入即补全,回车按原名直接查
    private var stationInput: some View {
        let suggestions = StationDirectory.shared.suggest(stationQuery, limit: 6)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.ticketGray)
                TextField("输入站名,如 北京南", text: $stationQuery)
                    .font(.system(size: 14))
                    .focused($inputFocused)
                    .autocorrectionDisabled()
                    .onSubmit {
                        let name = stationQuery.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        pick(name)
                        stationQuery = ""
                        showStationInput = false
                    }
                if !stationQuery.isEmpty {
                    Button {
                        stationQuery = ""
                        inputFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.ticketGray.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if !suggestions.isEmpty {
                Rectangle().fill(Theme.ticketGray.opacity(0.18)).frame(height: 0.5)
                ForEach(suggestions, id: \.n) { s in
                    Button {
                        pick(s.n)
                        stationQuery = ""
                        showStationInput = false
                    } label: {
                        HStack {
                            Text(s.n).font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.ticketInk)
                            Text(s.c).font(.system(size: 11)).foregroundColor(Theme.ticketGray)
                            Spacer()
                            if s.n == selectedStation {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.railBlue)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.creamPaper))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            PillSelector(options: [("昨天", -1), ("今天", 0), ("明天", 1)], selection: $dayOffset)
            PillSelector(options: [("出发", 0), ("终到", 1)], selection: $segment)
            modeToggle
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 3) {
            modeIcon("menubar.rectangle", 0)
            modeIcon("ticket", 1)
        }
        .padding(3)
        .background(Capsule().fill(Theme.creamPaper))
    }

    private func modeIcon(_ symbol: String, _ mode: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { displayMode = mode }
            UserDefaults.standard.set(mode, forKey: "board.mode")
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(displayMode == mode ? .white : Theme.ticketGray)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(displayMode == mode ? Theme.railBlue : .clear))
        }
    }

    /// 模糊搜索:车次包含(忽略大小写)或始发/终到站名包含
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(Theme.ticketGray)
            TextField("搜车次或车站,如 G12、南京", text: $query)
                .font(.system(size: 14))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ticketGray.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.creamPaper))
    }

    /// 搜索框 + 已发车筛选芯片(同行,不挤上方控制行)
    private var searchRow: some View {
        HStack(spacing: 8) {
            searchBar
            filterChip
        }
    }

    /// 已发车筛选:默认开着(开走的车不显示),点一下切回显示置灰的历史车
    private var filterChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { hideDeparted.toggle() }
            UserDefaults.standard.set(hideDeparted, forKey: "board.hideDeparted")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hideDeparted ? "eye.slash" : "eye")
                    .font(.system(size: 11, weight: .bold))
                Text("已发车")
                    .font(.system(size: 12, weight: hideDeparted ? .bold : .regular))
            }
            .foregroundColor(hideDeparted ? .white : Theme.ticketGray)
            .padding(.horizontal, 9).padding(.vertical, 9)
            .background(Capsule().fill(hideDeparted ? Theme.railBlue : Theme.creamPaper))
        }
    }

    private var searchResults: [BigScreenTrain] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return trains.filter { t in
            t.trainCode.lowercased().contains(q)
                || t.destination.contains(q) || t.origin.contains(q)
        }
        .sorted {
            Self.sortKey($0, segment: $0.terminating ? 1 : 0)
                < Self.sortKey($1, segment: $1.terminating ? 1 : 0)
        }
    }

    /// 大屏模式的平铺列表:已开车的只保留 12 分钟内的(票根模式放宽到 45 分钟)
    private var ledRows: [BigScreenTrain] {
        boardRows(maxGoneMinutes: 12)
    }

    /// 当日列表:方向过滤 + 已开车保留窗口(hideDeparted 开着则全部不显示)
    private func boardRows(maxGoneMinutes: Int) -> [BigScreenTrain] {
        let today = Calendar.current.isDateInToday(boardDay)
        let nowMin = Self.minutesNow()
        return trains.filter { $0.terminating == (segment == 1) }.filter { t in
            guard today, Self.isGone(t, day: boardDay), let m = Self.minuteOfDay(t.effectiveDepart) else {
                return true
            }
            return !hideDeparted && nowMin - m <= maxGoneMinutes
        }
        .sorted { Self.sortKey($0, segment: segment) < Self.sortKey($1, segment: segment) }
    }

    // MARK: 真实大屏(LED 暗板)

    private static let boardBlue = Color(red: 0.02, green: 0.16, blue: 0.38)
    private static let ledAmber = Color(red: 1.0, green: 0.72, blue: 0.28)
    private static let ledCyan = Color(red: 0.44, green: 0.82, blue: 0.96)
    private static let ledRed = Color(red: 1.0, green: 0.35, blue: 0.3)

    private func ledPanel(_ rows: [BigScreenTrain], searching: Bool) -> some View {
        VStack(spacing: 0) {
            ledHeader(searching: searching)
            if rows.isEmpty {
                Text(searching ? "没找到匹配的车次或车站" : (segment == 0 ? "当天暂无出发列车" : "当天暂无终到列车"))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, train in
                    ledRow(train, searching: searching)
                        .contentShape(Rectangle())
                        .onTapGesture { routeTrain = train }
                    if index < rows.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.horizontal, 10)
                    }
                }
            }
            if searching, !rows.isEmpty {
                Text("找到 \(rows.count) 班")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.03))
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Self.boardBlue))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    private func ledHeader(searching: Bool) -> some View {
        HStack(spacing: 0) {
            Text("车次").frame(width: 58, alignment: .leading)
            Text(searching ? "到 / 发站" : (segment == 0 ? "终点站" : "始发站"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(searching ? "时刻" : (segment == 0 ? "开点" : "到点"))
                .frame(width: 52, alignment: .trailing)
            Text("检票口").frame(width: 72, alignment: .trailing)
            Text("状态").frame(width: 66, alignment: .trailing)
            Text("站台").frame(width: 46, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(.white.opacity(0.4))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    private func ledRow(_ t: BigScreenTrain, searching: Bool) -> some View {
        let stop = liveByID[t.id]
        let gone = Self.isGone(t, day: boardDay)
        let delayed = gone ? 0 : (stop?.delayMinutes ?? 0)
        return VStack(spacing: 3) {
            HStack(spacing: 0) {
                Text(t.trainCode)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 58, alignment: .leading)
                HStack(spacing: 5) {
                    if searching {
                        Text(t.terminating ? "终" : "发")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Self.boardBlue)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Capsule().fill(Self.ledAmber.opacity(0.85)))
                    }
                    Text(t.terminating ? t.origin : t.destination)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    Text(t.effectiveDepart)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(delayed > 0 ? Self.ledRed : Self.ledAmber)
                    if let actual = t.actualDepart, actual != t.scheduledDepart {
                        Text("计划 \(t.scheduledDepart)")
                            .font(.system(size: 8))
                            .strikethrough()
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .frame(width: 52, alignment: .trailing)
                Text(stop?.gateDisplay ?? "--")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(stop?.gateDisplay != nil ? .white.opacity(0.9) : .white.opacity(0.3))
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72, alignment: .trailing)
                    .padding(.horizontal, 4)
                statusLED(stop, gone: gone)
                    .frame(width: 66, alignment: .trailing)
                Text(t.platform ?? "--")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(t.platform != nil ? Self.ledCyan : .white.opacity(0.3))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: 46, alignment: .trailing)
            }
            if let detail = ledDetail(t, stop: stop, gone: gone) {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 70)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(gone ? 0.4 : 1)
    }

    /// 行下细节:晚点 / 候车室 / 出站口(仅未发车且有实时数据时)
    private func ledDetail(_ t: BigScreenTrain, stop: TrainLiveStop?, gone: Bool) -> String? {
        guard !gone, let stop else { return nil }
        var parts: [String] = []
        if stop.delayMinutes > 0 { parts.append("晚点 \(stop.delayMinutes) 分") }
        if !t.terminating {
            let w = stop.waitingRoom.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty, w != "--" { parts.append("候车室 \(w)") }
        } else {
            let e = stop.exit.trimmingCharacters(in: .whitespaces)
            if !e.isEmpty, e != "--" { parts.append("出站口 \(e)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLED(_ stop: TrainLiveStop?, gone: Bool) -> some View {
        if gone {
            Text("已发车")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
        } else if let state = stop?.checkStateText {
            let boarding = state == "正在检票"
            HStack(spacing: 3) {
                if boarding { PulseDot() }
                Text(state)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(boarding ? Theme.routeGreen : .white.opacity(0.75))
            }
        } else {
            Text("--")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    private func hourHeader(_ hour: String) -> some View {
        HStack(spacing: 8) {
            Text("\(hour)点")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.ticketGray)
            Rectangle().fill(Theme.ticketGray.opacity(0.18)).frame(height: 0.5)
        }
        .padding(.top, 6)
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 34))
                .foregroundColor(Theme.ticketGray.opacity(0.6))
            Text("先选一个车站,看它的当日大屏")
                .font(.system(size: 13))
                .foregroundColor(Theme.ticketGray)
            Button("选择车站") {
                withAnimation(.easeOut(duration: 0.2)) { showStationInput = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inputFocused = true }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(Theme.railBlue)
        }
        .padding(.top, 60)
    }

    private func pick(_ name: String) {
        selectedStation = name
        UserDefaults.standard.set(name, forKey: "board.station")
        trains = []
        liveByID = [:]
        loaded = false
        errorText = nil
    }

    // MARK: 数据

    private var boardDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset,
                              to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    /// 按小时分组展示;今天只保留发车 45 分钟内的已开车(更早的退出列表,聚焦眼前)
    private var grouped: [(hour: String, trains: [BigScreenTrain])] {
        let rows = boardRows(maxGoneMinutes: 45)
        let buckets = Dictionary(grouping: rows) { key(for: $0) }
        return buckets.keys.sorted().map { hour in
            (hour, buckets[hour]!.sorted { Self.sortKey($0, segment: segment) < Self.sortKey($1, segment: segment) })
        }
    }

    private func key(for t: BigScreenTrain) -> String {
        let raw = segment == 1 ? t.scheduledArrive : t.effectiveDepart
        return (raw.isEmpty || raw == "----") ? "99" : String(raw.prefix(2))
    }

    private static func sortKey(_ t: BigScreenTrain, segment: Int) -> String {
        let raw = segment == 1 ? t.scheduledArrive : t.effectiveDepart
        return raw.isEmpty || raw == "----" ? "99:99" : raw
    }

    /// 今天的车已开出(按实际开点估,晚点数据未知时按计划)
    private static func isGone(_ t: BigScreenTrain, day: Date) -> Bool {
        guard Calendar.current.isDateInToday(day), let m = minuteOfDay(t.effectiveDepart) else { return false }
        return m <= minutesNow()
    }

    private static func minutesNow() -> Int {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (now.hour ?? 0) * 60 + (now.minute ?? 0)
    }

    private static func minuteOfDay(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else {
            return nil
        }
        return h * 60 + m
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard !selectedStation.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await TrainLiveService.shared.bigScreen(
                station: selectedStation, day: boardDay, forceRefresh: force)
            trains = list
            loaded = true
            lastUpdated = Date()
            errorText = nil
            await fetchLive(list)
        } catch {
            errorText = "加载失败,下拉重试"
        }
    }

    /// 只为今天临近发车的车拉实时状态(检票口/检票状态/晚点),别把全天几百趟都拉一遍
    @MainActor
    private func fetchLive(_ list: [BigScreenTrain]) async {
        guard Calendar.current.isDateInToday(boardDay) else { return }
        let station = selectedStation
        let nowMin = Self.minutesNow()
        let upcoming = Array(list.filter { t in
            guard !t.terminating, let m = Self.minuteOfDay(t.effectiveDepart) else { return false }
            return (-60 ..< 150).contains(m - nowMin)
        }.prefix(36))
        guard !upcoming.isEmpty else { return }

        var fetched: [String: TrainLiveStop] = [:]
        await withTaskGroup(of: (String, TrainLiveStop?).self) { group in
            for t in upcoming {
                group.addTask {
                    let info = try? await TrainLiveService.shared.live(
                        trainCode: t.trainCode, date: Date())
                    return (t.id, info.flatMap { $0.stop(at: station) })
                }
            }
            for await (id, stop) in group {
                if let stop { fetched[id] = stop }
            }
        }
        liveByID.merge(fetched) { _, new in new }
    }

    // MARK: 票根行

    private func stub(_ t: BigScreenTrain) -> some View {
        let stop = liveByID[t.id]
        let gone = Self.isGone(t, day: boardDay)
        let delayed = stop?.delayMinutes ?? 0
        // 彩色边条:与票根列表同一套 routeColor,同车次颜色固定
        let accent = Theme.routeColor(from: t.trainCode, to: t.destination)
        return HStack(spacing: 0) {
            // 左截:时刻 + 站台
            VStack(alignment: .leading, spacing: 3) {
                Text(t.effectiveDepart)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(delayed > 0 ? Theme.railRed : Theme.ticketInk)
                if let actual = t.actualDepart, actual != t.scheduledDepart {
                    Text("计划 \(t.scheduledDepart)")
                        .font(.system(size: 9))
                        .strikethrough()
                        .foregroundColor(Theme.ticketGray)
                }
                if delayed > 0 {
                    Text("晚点 \(delayed) 分")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.railRed)
                }
                if let platform = t.platform {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("站台").font(.system(size: 9)).foregroundColor(Theme.ticketGray)
                        Text(platform)
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundColor(Theme.railBlue)
                    }
                    .padding(.top, 1)
                }
            }
            .frame(width: 88, alignment: .leading)
            .padding(.leading, 13)
            .padding(.vertical, 11)

            // 打孔撕裂线
            perforation
                .frame(width: 16)

            // 右截:车次 + 状态 + 去向 + 检票口
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 6) {
                    Text(t.trainCode)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.ticketInk)
                    Spacer(minLength: 6)
                    statusBadge(stop, gone: gone)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(t.terminating ? "来自" : "开往")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.ticketGray)
                    Text(t.terminating ? t.origin : t.destination)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                }
                if let gate = stop?.gateDisplay {
                    Text("检票口 \(gate)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.ticketGray)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.creamPaper))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).fill(accent).frame(width: 4),
            alignment: .leading
        )
        .shadow(color: .black.opacity(0.07), radius: 5, y: 3)
        .opacity(gone ? 0.35 : 1)
    }

    /// 中缝票据撕裂线(复用票面组件)
    private var perforation: some View {
        TicketTear(lineColor: Theme.ticketGray.opacity(0.4), punchColor: Theme.paperBackground)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func statusBadge(_ stop: TrainLiveStop?, gone: Bool) -> some View {
        if gone {
            // 已开出:不显示可能过期的实时状态,统一标已发车
            Text("已发车")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.ticketGray)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.ticketGray.opacity(0.10)))
        } else if let state = stop?.checkStateText {
            let boarding = state == "正在检票"
            HStack(spacing: 4) {
                if boarding { PulseDot() }
                Text(state).font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(boarding ? Theme.routeGreen : Theme.ticketGray)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(boarding ? Theme.routeGreen.opacity(0.14)
                                                : Theme.ticketGray.opacity(0.10)))
        }
    }
}

/// 胶囊分段选择:纸面胶囊里选中项填铁路蓝
private struct PillSelector: View {
    let options: [(String, Int)]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.1) { label, value in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selection == value ? .bold : .regular))
                        .foregroundColor(selection == value ? .white : Theme.ticketGray)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(selection == value ? Theme.railBlue : .clear))
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.creamPaper))
    }
}

private extension BigScreenTrain {
    /// 展示用开点:优先实际/预计,没有用计划;未知返回占位
    var effectiveDepart: String {
        actualDepart ?? (scheduledDepart.isEmpty || scheduledDepart == "----" ? "--:--" : scheduledDepart)
    }
}

// MARK: - 车次时刻表详情(大屏点进来)

/// 大屏行的车次详情:经停时刻表(12306 时刻表接口),标出大屏所在车站
private struct TrainRouteView: View {
    let train: BigScreenTrain
    /// 大屏当前所选车站(出发方向 = 乘车站,终到方向 = 到站)
    let station: String
    let day: Date

    @State private var stops: [TrainStop] = []
    @State private var failed = false

    /// 两个方向统一映射成「始发 → 终到」的 OD 去查时刻表
    private var fromStation: String { train.terminating ? train.origin : station }
    private var toStation: String { train.terminating ? station : train.destination }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if failed {
                    Label("没查到这趟车的时刻表,下拉重试", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ticketGray)
                        .padding(.top, 40)
                } else if stops.isEmpty {
                    ProgressView().padding(.top, 60)
                } else {
                    timetable
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(Theme.paperBackground.ignoresSafeArea())
        .navigationTitle(train.trainCode)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(train.trainCode)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                if let platform = train.platform {
                    Text("站台 \(platform)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            Text("\(fromStation) → \(toStation)")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(Fmt.dotDate.string(from: day))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Theme.railBlueDeep, Theme.railBlue,
                                              Color(red: 0.16, green: 0.42, blue: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.railBlue.opacity(0.35), radius: 12, y: 6)
        )
    }

    private var timetable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("车站").frame(maxWidth: .infinity, alignment: .leading)
                Text("到达").frame(width: 62, alignment: .trailing)
                Text("开车").frame(width: 62, alignment: .trailing)
                Text("停留").frame(width: 62, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.ticketGray)
            .padding(.horizontal, 14).padding(.vertical, 8)

            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                if index > 0 {
                    Rectangle().fill(Theme.ticketGray.opacity(0.18)).frame(height: 0.5)
                        .padding(.horizontal, 14)
                }
                stopRow(stop, index: index)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.creamPaper))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.07), radius: 5, y: 3)
    }

    private func stopRow(_ stop: TrainStop, index: Int) -> some View {
        let isBoardStation = TrainLiveService.looseMatch(stop.stationName, station)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(isBoardStation ? Theme.railBlue : Theme.ticketGray.opacity(0.5)))
                Text(stop.stationName)
                    .font(.system(size: 14, weight: isBoardStation ? .heavy : .medium))
                    .foregroundColor(isBoardStation ? Theme.railBlue : Theme.ticketInk)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if isBoardStation {
                    Text("本站")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.railBlue))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stopTimeText(stop.arriveTime)
                .frame(width: 62, alignment: .trailing)
            stopTimeText(stop.departTime)
                .frame(width: 62, alignment: .trailing)
            Text(stop.stopoverText)
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketGray)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(isBoardStation ? Theme.railBlue.opacity(0.07) : .clear)
    }

    private func stopTimeText(_ raw: String) -> some View {
        let empty = raw.isEmpty || raw == "----"
        return Text(empty ? "——" : raw)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(empty ? Theme.ticketGray.opacity(0.5) : Theme.ticketInk)
    }

    private func load() async {
        failed = false
        do {
            stops = try await TrainScheduleService.shared.stops(
                trainNo: train.trainCode,
                fromStation: fromStation,
                toStation: toStation,
                date: day)
            failed = stops.isEmpty
        } catch {
            failed = true
        }
    }
}
