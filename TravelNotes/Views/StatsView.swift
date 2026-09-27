import SwiftUI
import SwiftData
import Charts

/// 「统计」页:总览、年度趋势、线路/城市排行、车型席别分布、之最
struct StatsView: View {
    @Query(sort: \TicketEntry.date, order: .reverse) private var entries: [TicketEntry]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if entries.isEmpty {
                        emptyView
                    } else {
                        overviewCard
                        card("年度乘车次数") { yearChart }
                        card("常走的线路 TOP5") { routeList }
                        card("到访城市 TOP5") { cityList }
                        card("车型分布") { kindChart }
                        card("席别分布") { seatChart }
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

    // MARK: 总览

    private var overviewCard: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            statTile("累计乘车", "\(entries.count)", "次")
            statTile("总里程", mileageText, "")
            statTile("途经车站", "\(uniqueStations.count)", "个")
            statTile("购票花费", spendText, "")
        }
        .padding(16)
        .background(cardBackground)
    }

    private func statTile(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketGray)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.railRed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 12)).foregroundColor(Theme.ticketGray)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 年度趋势

    private var yearChart: some View {
        let counts = Dictionary(grouping: entries) { Calendar.current.component(.year, from: $0.date) }
            .map { (year: $0.key, count: $0.value.count) }
            .sorted { $0.year < $1.year }
        return Chart(counts, id: \.year) { item in
            BarMark(
                x: .value("年份", String(item.year)),
                y: .value("次数", item.count)
            )
            .foregroundStyle(Theme.railRed.gradient)
            .cornerRadius(4)
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
        .frame(height: 150)
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

    // MARK: 车型分布

    private var kindChart: some View {
        let counts = Dictionary(grouping: entries) { entry -> String in
            guard let no = entry.trainNo, !no.isEmpty, let kind = entry.kindDescription else { return "未填车次" }
            switch kind {
            case "高速动车", "动车组", "城际列车": return "高铁动车"
            default: return "普速列车"
            }
        }
        .map { (kind: $0.key, count: $0.value.count) }
        .sorted { $0.count > $1.count }
        return Chart(counts, id: \.kind) { item in
            BarMark(
                x: .value("次数", item.count),
                y: .value("车型", item.kind)
            )
            .foregroundStyle(Theme.railBlue.gradient)
            .cornerRadius(3)
        }
        .chartXAxis { AxisMarks(position: .bottom) }
        .frame(height: CGFloat(max(70, counts.count * 34)))
    }

    // MARK: 席别分布

    private var seatChart: some View {
        let counts = Dictionary(grouping: entries) { ($0.seatClass?.isEmpty == false) ? $0.seatClass! : "未填" }
            .map { (seat: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        return Chart(counts, id: \.seat) { item in
            BarMark(
                x: .value("次数", item.count),
                y: .value("席别", item.seat)
            )
            .foregroundStyle(Theme.railRed.opacity(0.75).gradient)
            .cornerRadius(3)
        }
        .frame(height: CGFloat(max(70, counts.count * 30)))
    }

    // MARK: 之最

    private var recordsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let earliest = entries.last {
                recordRow("最早一张", Fmt.dotDate.string(from: earliest.date),
                          routeText(earliest))
            }
            if let maxPrice = entries.max(by: { ($0.price ?? 0) < ($1.price ?? 0) }),
               let price = maxPrice.price, price > 0 {
                let text = price.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "¥%.0f", price)
                    : String(format: "¥%.1f", price)
                recordRow("最贵一张", text,
                          "\(maxPrice.trainNo ?? "") \(routeText(maxPrice))")
            }
            if let longest = entries
                .filter({ entry -> Bool in
                    let km = tripKm(entry)
                    return km > 0
                })
                .max(by: { tripKm($0) < tripKm($1) }) {
                recordRow("单程最远", "\(Int(tripKm(longest))) km",
                          "\(longest.trainNo ?? "") \(routeText(longest))")
            }
        }
    }

    private func recordRow(_ label: String, _ value: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketGray)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.railRed)
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(Theme.ticketInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
        }
    }

    // MARK: 排行条目

    private func rankingRows(_ items: [(String, Int)], unit: String) -> some View {
        let maxCount = items.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(index + 1). \(item.0)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.ticketInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        Text("\(item.1) \(unit)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.railRed)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(Theme.railRed.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Theme.railRed.gradient)
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
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white.opacity(0.85))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(Theme.ticketInk)
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
