import SwiftUI

/// 票面/页面共用配色与格式化
enum Theme {
    /// 首页纸质底色
    static let paperBackground = Color(red: 0.964, green: 0.941, blue: 0.902)
    /// 红票米黄纸
    static let creamPaper = Color(red: 0.988, green: 0.949, blue: 0.878)
    static let railRed = Color(red: 0.729, green: 0.196, blue: 0.153)
    static let railRedDeep = Color(red: 0.604, green: 0.145, blue: 0.110)
    static let railBlue = Color(red: 0.086, green: 0.322, blue: 0.580)
    static let railBlueDeep = Color(red: 0.051, green: 0.220, blue: 0.439)
    static let ticketInk = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let ticketGray = Color(red: 0.45, green: 0.47, blue: 0.50)

    // MARK: 线路方向配色(票根卡与足迹弧线)

    /// 回到上海:蓝(默认)
    static let routeBlue = railBlue
    /// 从上海出发:绿
    static let routeGreen = Color(red: 0.13, green: 0.60, blue: 0.35)
    /// 其他线路调色板(同一线路颜色稳定)
    static let routePalette: [Color] = [
        Color(red: 0.85, green: 0.49, blue: 0.18),
        Color(red: 0.54, green: 0.36, blue: 0.76),
        Color(red: 0.10, green: 0.55, blue: 0.52),
        Color(red: 0.80, green: 0.34, blue: 0.44)
    ]

    /// 按行程方向取色:到上海=蓝,从上海出发=绿,其他线路按线路稳定取调色板
    static func routeColor(from: String?, to: String?) -> Color {
        let fromCity = from.flatMap { StationDirectory.shared.resolve($0)?.c }
        let toCity = to.flatMap { StationDirectory.shared.resolve($0)?.c }
        if toCity == "上海" { return routeBlue }
        if fromCity == "上海" { return routeGreen }
        guard fromCity != nil || toCity != nil else { return ticketGray }
        let key = (from ?? "") + ">" + (to ?? "")
        let hash = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return routePalette[hash % routePalette.count]
    }
}

enum Fmt {
    static let cnDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年MM月dd日"
        return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
    static let dotDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()
}

/// 票面展示所需的数据快照(与存储解耦,表单预览也用它)
struct TicketInfo {
    var trainNo: String?
    var from: String?
    var to: String?
    var date: Date
    var departTime: Date?
    var coach: String?
    var seat: String?
    var seatClass: String?
    var price: Double?
    var skin: TicketSkin
    var kind: String?
    var photoCount: Int = 0
    var hasNote: Bool = false
    var passenger: String?

    init(entry: TicketEntry) {
        trainNo = entry.trainNo
        from = entry.fromStation
        to = entry.toStation
        date = entry.date
        departTime = entry.departTime
        coach = entry.coach
        seat = entry.seat
        seatClass = entry.seatClass
        price = entry.price
        skin = entry.skin
        kind = entry.kindDescription
        photoCount = entry.photoFileNames.count
        hasNote = entry.note?.isEmpty == false
        passenger = entry.passenger
    }

    init(trainNo: String? = nil, from: String? = nil, to: String? = nil,
         date: Date = Date(), departTime: Date? = nil,
         coach: String? = nil, seat: String? = nil, seatClass: String? = nil,
         price: Double? = nil, skin: TicketSkin = .blue) {
        self.trainNo = trainNo
        self.from = from
        self.to = to
        self.date = date
        self.departTime = departTime
        self.coach = coach
        self.seat = seat
        self.seatClass = seatClass
        self.price = price
        self.skin = skin
        self.kind = TrainKind.describe(trainNo)
    }

    var priceText: String? {
        guard let p = price, p > 0 else { return nil }
        return p.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "¥%.0f", p)
            : String(format: "¥%.1f", p)
    }

    /// 磁卡票版式的完整票价:¥471.00元
    var priceFullText: String {
        guard let p = price, p > 0 else { return "¥0.00元" }
        return String(format: "¥%.2f元", p)
    }

    /// 磁卡票底部的长票号(装饰,由乘车日期推导)
    var longSerialText: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        let digits = String(format: "%012d", (day * 31337) % 1_000_000_000_000 % 1_000_000_000_000)
        return "203\(String(digits.suffix(10)))\(serialText)"
    }

    var trainNoText: String {
        guard let no = trainNo, !no.isEmpty else { return "——" }
        return no
    }
    var trainNoLine: String { trainNoText + " 次" }

    var stationFrom: String { Self.stationText(from) }
    var stationTo: String { Self.stationText(to) }
    static func stationText(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "——" }
        return s
    }

    var seatLine: String {
        let c = coach.flatMap { $0.isEmpty ? nil : $0 }
        let s = seat.flatMap { $0.isEmpty ? nil : $0 }
        switch (c, s) {
        case (nil, nil): return "— —"
        case (let c?, nil): return c
        case (nil, let s?): return s
        case (let c?, let s?): return c + " " + s
        }
    }

    /// 红票底部的票号(由乘车日期推导,确定性的装饰值)
    var serialText: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        let v = (day * 7919) % 900_000 + 100_000
        return "E\(v)"
    }

    /// 线路方向配色(到上海=蓝,从上海出发=绿,其他线路其他色)
    var routeColor: Color { Theme.routeColor(from: from, to: to) }
}
