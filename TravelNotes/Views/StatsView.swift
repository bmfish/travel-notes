import SwiftUI
import SwiftData
import Charts

/// 「统计」页:渐变总览、年度趋势、排行、环形分布、之最徽章
struct StatsView: View {
    @Query(sort: \TicketEntry.date, order: .reverse) private var entries: [TicketEntry]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if entries.isEmpty {
                        emptyView
                    } else {
                        heroCard
                        card("年度乘车次数") { yearChart }
                        card("常走的线路 TOP5") { routeList }
                        card("到访城市 TOP5") { cityList }
                        card("车型分布") { kindDonut }
                        card("席别分布") { seatDonut }
                        card("之最") { recordsList }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .background(Theme.paperBackground.ignoresSafeArea())
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 渐变总览

    private var heroCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("旅行总览")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                    Text("\(entries.count) 段旅程")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Image(systemName: "tram.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.5))
            }
            HStack(spacing: 10) {
                heroStat("总里程", mileageText, "km", "arrow.left.and.right")
                heroStat("途经车站", "\(uniqueStations.count)", "个", "mappin.and.ellipse")
                heroStat("购票花费", "¥\(spendText)", "", "yensign.circle")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(colors: [Theme.railBlueDeep, Theme.railBlue,
                                            Color(red: 0.16, green: 0.42, blue: 0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: Theme.railBlue.opacity(0.35), radius: 12, y: 6)
        )
    }

    private func heroStat(_ label: String, _ value: String, _ unit: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
    }

    // MARK: 年度趋势

    private var yearChart: some View {
        let counts = Dictionary(grouping: entries) { Calendar.current.component(.year, from: $0.date) }
            .map { (year: $0.key, count: $0.value.count) }
            .sorted { $0.year < $1.year }
        let maxCount = counts.map(\.count).max() ?? 1
        return Chart(counts, id: \.year) { item in
            BarMark(
                x: .value("年份", String(item.year)),
                y: .value("次数", item.count)
            )
            .foregroundStyle(
                item.count == maxCount ? AnyShapeStyle(Theme.railRed.gradient)
                                       : AnyShapeStyle(Theme.railRed.opacity(0.45).gradient)
            )
            .cornerRadius(5)
            .annotation(position: .top, spacing: 4) {
                Text("\(item.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.ticketGray)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.clear)
                AxisValueLabel {
                    if let y = value.as(String.self) {
                        Text(String(y.suffix(2))).font(.system(size: 10))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.ticketInk.opacity(0.06))
                AxisValueLabel().foregroundStyle(Theme.ticketGray)
            }
        }
        .frame(height: 170)
    }

    // MARK: 线路 TOP5

    private var routeList: some View {
        let pairs = Dictionary(grouping: entries.filter { $0.fromStation != nil && $0.toStation != nil }) {
            let names = [$0.fromStation!, $0.toStation!].sorted()
            return names.joined(separator: " ⇄ ")
        }
        let top = pairs.map { (label: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(5)
        return rankingRows(top.map { ($0.label, $0.count) }, unit: "次")
    }

    // MARK: 城市 TOP5

    private var cityList: some View {
        var cityCounts: [String: Int] = [:]
        for entry in entries {
            for name in [entry.fromStation, entry.toStation] {
                guard let name, !name.isEmpty,
                      let station = StationDirectory.shared.resolve(name) else { continue }
                cityCounts[station.c, default: 0] += 1
            }
        }
        let top = cityCounts.sorted { $0.value > $1.value }.prefix(5)
            .map { ($0.key, $0.value) }
        return rankingRows(top, unit: "次")
    }

    // MARK: 车型环形图

    private var kindDonut: some View {
        let counts = Dictionary(grouping: entries) { entry -> String in
            guard let no = entry.trainNo, !no.isEmpty, let kind = entry.kindDescription else { return "未填车次" }
            switch kind {
            case "高速动车", "动车组", "城际列车": return "高铁动车"
            default: return "普速列车"
            }
        }
        .map { (kind: $0.key, count: $0.value.count) }
        .sorted { $0.count > $1.count }
        let colors = [Theme.railBlue, Theme.railRed, Theme.routeGreen, Theme.ticketGray]
        return VStack(spacing: 8) {
            Chart(counts, id: \.kind) { item in
                let idx = counts.firstIndex { $0.kind == item.kind } ?? 0
                SectorMark(
                    angle: .value("次数", item.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .foregroundStyle(colors[idx % colors.count].gradient)
                .cornerRadius(4)
            }
            .frame(height: 120)
            .overlay(
                VStack(spacing: 0) {
                    Text("\(entries.count)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.ticketInk)
                    Text("总计")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.ticketGray)
                }
            )
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(counts.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(colors[idx % colors.count])
                            .frame(width: 7, height: 7)
                        Text(item.kind)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.ticketInk.opacity(0.8))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.ticketGray)
                    }
                }
            }
        }
    }

    // MARK: 席别环形图

    private var seatDonut: some View {
        let counts = Dictionary(grouping: entries) { ($0.seatClass?.isEmpty == false) ? $0.seatClass! : "未填" }
            .map { (seat: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        let colors = [Theme.routeGreen, Theme.railBlue, Theme.railRed,
                      Theme.routePalette[0], Theme.routePalette[1], Theme.routePalette[2]]
        return VStack(spacing: 8) {
            Chart(counts, id: \.seat) { item in
                let idx = counts.firstIndex { $0.seat == item.seat } ?? 0
                SectorMark(
                    angle: .value("次数", item.count),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .foregroundStyle(colors[idx % colors.count].gradient)
                .cornerRadius(4)
            }
            .frame(height: 120)
            .overlay(
                VStack(spacing: 0) {
                    Text("\(counts.count)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.ticketInk)
                    Text("席别")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.ticketGray)
                }
            )
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(counts.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(colors[idx % colors.count])
                            .frame(width: 7, height: 7)
                        Text(item.seat)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.ticketInk.opacity(0.8))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.ticketGray)
                    }
                }
            }
        }
    }

    // MARK: 之最

    private var recordsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let earliest = entries.last {
                recordRow("clock", "最早一张", Fmt.dotDate.string(from: earliest.date),
                          routeText(earliest), Theme.railBlue)
            }
            if let maxPrice = entries.max(by: { ($0.price ?? 0) < ($1.price ?? 0) }),
               let price = maxPrice.price, price > 0 {
                let text = price.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "¥%.0f", price)
                    : String(format: "¥%.1f", price)
                recordRow("yensign.circle.fill", "最贵一张", text,
                          "\(maxPrice.trainNo ?? "") \(routeText(maxPrice))", Theme.railRed)
            }
            if let longest = entries
                .filter({ entry -> Bool in
                    let km = tripKm(entry)
                    return km > 0
                })
                .max(by: { tripKm($0) < tripKm($1) }) {
                recordRow("arrow.left.and.right.circle.fill", "单程最远", "\(Int(tripKm(longest))) km",
                          "\(longest.trainNo ?? "") \(routeText(longest))", Theme.routeGreen)
            }
        }
    }

    private func recordRow(_ icon: String, _ label: String, _ value: String, _ detail: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.ticketGray)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundColor(tint)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.ticketInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(0.06))
        )
    }

    // MARK: 排行条目

    private func rankingRows(_ items: [(String, Int)], unit: String) -> some View {
        let maxCount = items.map(\.1).max() ?? 1
        let barColors = [Theme.railRed, Theme.railBlue, Theme.routeGreen,
                         Theme.routePalette[0], Theme.routePalette[1]]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(index < 3
                                             ? AnyShapeStyle(barColors[index].gradient)
                                             : AnyShapeStyle(Theme.ticketGray.opacity(0.5)))
                            )
                        Text(item.0)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.ticketInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        Text("\(item.1) \(unit)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(barColors[index % barColors.count])
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(Theme.ticketInk.opacity(0.05))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(barColors[index % barColors.count].gradient)
                                    .frame(width: geo.size.width * CGFloat(item.1) / CGFloat(maxCount))
                            }
                    }
                    .frame(height: 6)
                }
            }
        }
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

    private var mileageText: String {
        let km = Int(MileageEstimator.totalKm(entries: entries))
        return km >= 10000 ? String(format: "%.1f万", Double(km) / 10000) : "\(km)"
    }

    private var spendText: String {
        let total = entries.compactMap(\.price).reduce(0, +)
        return total >= 10000 ? String(format: "%.1f万", total / 10000) : String(format: "%.0f", total)
    }

    private func tripKm(_ entry: TicketEntry) -> Double {
        guard let f = entry.fromStation.flatMap({ StationDirectory.shared.resolve($0) }),
              let t = entry.toStation.flatMap({ StationDirectory.shared.resolve($0) }) else { return 0 }
        return MileageEstimator.kmBetween(f, t)
    }

    private func routeText(_ entry: TicketEntry) -> String {
        "\(TicketInfo.stationText(entry.fromStation))→\(TicketInfo.stationText(entry.toStation))"
    }

    // MARK: 通用

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.9))
            .shadow(color: .black.opacity(0.07), radius: 6, y: 3)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.railRed)
                    .frame(width: 4, height: 14)
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(Theme.ticketInk)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 34))
                .foregroundColor(Theme.ticketGray.opacity(0.6))
            Text("还没有票根,先去记一笔或同步")
                .font(.system(size: 14))
                .foregroundColor(Theme.ticketGray)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}
