import Foundation

/// 从订票邮件正文解析候选票根。启发式解析,候选一律经用户在表单里确认后入库。
enum TicketMailParser {
    struct ParsedTicket {
        var date: Date?
        var trainNo: String?
        var fromStation: String?
        var toStation: String?
        var departTimeText: String?
        var coach: String?
        var seat: String?
        var seatClass: String?
        var price: Double?
        var passenger: String?
    }

    static let seatClassOptions = ["商务座", "优选一等座", "一等座", "二等座", "软卧", "硬卧", "动卧", "软座", "硬座", "无座"]

    /// 判断这封邮件是否像订票通知(发件人/主题包含 12306 或购票关键词);退票/退单不算乘车
    static func looksLikeTicketMail(from: String, subject: String) -> Bool {
        let s = (from + " " + subject).lowercased()
        if s.contains("退票") || s.contains("退单") { return false }
        if s.contains("12306") { return true }
        let keywords = ["车票", "购票", "订票", "行程", "火车票"]
        return keywords.contains { s.contains($0) }
    }

    // MARK: 解析

    static func parse(subject: String, bodyText: String, owner: String? = nil) -> [ParsedTicket] {
        var text = bodyText
        // 截掉 12306 邮件尾部的"温馨提示/退票规则"样板文字,防止拼出假行程
        for marker in ["温馨提示", "退票规则", "铁路旅客禁止"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        guard !text.isEmpty else { return [] }

        // 车次号:前后不能是字母数字,避免命中订单号(如 EC58571374 里的 C5857)
        let trainMatches = allMatches(of: "(?<![A-Za-z0-9])[GDCTKLY]\\d{1,4}(?!\\d)", in: text)
        guard !trainMatches.isEmpty else { return [] }

        // 邮件里的编号乘车人列表("1.张三," "2.高小玉,"),用于只保留本人票
        let passengerItems = passengerItems(in: text)

        let pairMatches = stationPairMatches(in: text)
        let stationHits = findStations(in: text)
        let dateMatches = allMatches(of: "20\\d{2}\\s*[年-]\\s*\\d{1,2}\\s*[月-]\\s*\\d{1,2}\\s*日?", in: text)
        let timeMatches = allMatches(of: "([01]?\\d|2[0-3]):[0-5]\\d", in: text)

        var seen = Set<String>()
        var tickets: [ParsedTicket] = []
        for tm in trainMatches {
            let p = tm.range.lowerBound
            var ticket = ParsedTicket()
            ticket.trainNo = normalizeTrainNo(tm.text)

            // 乘车人归属:车次号前面最近的编号项姓名;无编号项的单人邮件按姓名就近判断
            let segmentPassenger = passengerItems.last { $0.pos < p }?.name
            if let owner, !owner.isEmpty {
                if let segmentPassenger {
                    guard segmentPassenger == owner else { continue }
                } else if passengerItems.isEmpty {
                    guard allMatches(of: NSRegularExpression.escapedPattern(for: owner), in: text)
                        .contains(where: { Self.offsetDistance($0.range.lowerBound, p, text) < 200 }) else { continue }
                    ticket.passenger = owner
                } else {
                    continue
                }
            }
            ticket.passenger = segmentPassenger ?? owner

            // 站名:优先取"出发站-到达站"配对结构,退化为最近两个"不同名"站
            if let pair = pairMatches.min(by: {
                Self.offsetDistance($0.range.lowerBound, p, text) < Self.offsetDistance($1.range.lowerBound, p, text)
            }) {
                ticket.fromStation = pair.from
                ticket.toStation = pair.to
            } else {
                let nearNames = stationHits
                    .sorted { Self.offsetDistance($0.range.lowerBound, p, text) < Self.offsetDistance($1.range.lowerBound, p, text) }
                    .map(\.text)
                var uniqueNames: [String] = []
                for name in nearNames where !uniqueNames.contains(name) {
                    uniqueNames.append(name)
                }
                if uniqueNames.count >= 1 { ticket.fromStation = uniqueNames[0] }
                if uniqueNames.count >= 2 { ticket.toStation = uniqueNames[1] }
            }
            // 日期:取离车次号最近的日期
            if let d = nearest(dateMatches, to: p, in: text), let date = parseDate(d.text) {
                ticket.date = date
            }
            // 时刻:最近的两个时间
            let times = timeMatches
                .map { (hit: $0, dist: Self.offsetDistance($0.range.lowerBound, p, text)) }
                .sorted { $0.dist < $1.dist }
                .prefix(2)
                .map { $0.hit.text }
            if times.count >= 2 {
                ticket.departTimeText = times.min() ?? times[0]
            } else if times.count == 1 {
                ticket.departTimeText = times[0]
            }
            // 席别 / 票价 / 车厢座位
            for sc in seatClassOptions where ticket.seatClass == nil {
                if text.contains(sc) { ticket.seatClass = sc }
            }
            ticket.price = nearestPrice(in: text, around: p)
            if let seatPair = parseCoachSeat(text, around: p) {
                ticket.coach = seatPair.coach
                ticket.seat = seatPair.seat
            }

            let key = "\(ticket.trainNo ?? "")|\(ticket.fromStation ?? "")|\(ticket.toStation ?? "")"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            // 同名站对无意义(多乘客邮件里同一站名出现多次导致),到达站留空给用户补
            if ticket.fromStation != nil, ticket.fromStation == ticket.toStation {
                ticket.toStation = nil
            }
            tickets.append(ticket)
        }
        return tickets.filter { $0.fromStation != nil || $0.toStation != nil }
    }

    // MARK: 组件

    private struct Hit {
        let range: Range<String.Index>
        let text: String
    }

    private struct StationPair {
        let range: Range<String.Index>
        let from: String
        let to: String
    }

    /// 用字符偏移衡量位置差(String.Index 不能直接相减)
    private static func offsetDistance(_ a: String.Index, _ b: String.Index, _ text: String) -> Int {
        abs(text.distance(from: a, to: b))
    }

    /// "郑州东站-开封站"/"杭州东至上海虹桥" 形态的站名对,两侧必须能解析为已知车站
    private static func stationPairMatches(in text: String) -> [StationPair] {
        guard let regex = stationPairRegex else { return [] }
        var pairs: [StationPair] = []
        let full = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 3,
                  let r1 = Range(match.range(at: 1), in: text),
                  let r2 = Range(match.range(at: 2), in: text),
                  let wholeRange = Range(match.range, in: text) else { return }
            let from = normalizeStation(String(text[r1]))
            let to = normalizeStation(String(text[r2]))
            guard from != to else { return }
            pairs.append(StationPair(range: wholeRange, from: from, to: to))
        }
        return pairs
    }

    private static func normalizeStation(_ s: String) -> String {
        var name = s.trimmingCharacters(in: .whitespaces)
        if name.count > 2, name.hasSuffix("站") { name.removeLast() }
        return name
    }

    private static var stationPairRegex: NSRegularExpression? = {
        let names = StationDirectory.shared.stations.map(\.n).sorted { $0.count > $1.count }
        guard !names.isEmpty else { return nil }
        let alternation = names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "((?:\(alternation))站?)\\s*[-—－–—至到~→＞>]{1,3}\\s*((?:\(alternation))站?)"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static func allMatches(of pattern: String, in text: String) -> [Hit] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var hits: [Hit] = []
        let full = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            hits.append(Hit(range: range, text: String(text[range])))
        }
        return hits
    }

    private static func nearest(_ hits: [Hit], to position: String.Index, in text: String) -> Hit? {
        hits.min { offsetDistance($0.range.lowerBound, position, text) < offsetDistance($1.range.lowerBound, position, text) }
    }

    /// 邮件正文的编号乘车人项:"1.张三," / "1、张三," -> (位置, 姓名)
    private static func passengerItems(in text: String) -> [(pos: String.Index, name: String)] {
        guard let regex = try? NSRegularExpression(pattern: "\\d{1,2}\\s*[.、．]\\s*([\u{4e00}-\u{9fa5}]{2,4})\u{FF0C}") else { return [] }
        var items: [(pos: String.Index, name: String)] = []
        let full = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let nameRange = Range(match.range(at: 1), in: text),
                  let posRange = Range(match.range, in: text) else { return }
            items.append((pos: posRange.lowerBound, name: String(text[nameRange])))
        }
        return items
    }

    private static func normalizeTrainNo(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: " ", with: "")
    }

    private static func parseDate(_ s: String) -> Date? {
        let digits = s.compactMap { $0.isNumber ? $0 : nil }
        guard digits.count >= 8 else { return nil }
        var comps = DateComponents()
        let y = Int(String(digits[0..<4]))
        let m = Int(String(digits[4..<6]))
        let d = Int(String(digits[6..<8]))
        guard let year = y, let month = m, let day = d else { return nil }
        comps.year = year; comps.month = month; comps.day = day
        return Calendar.current.date(from: comps)
    }

    /// 站名词扫描:内置站名表逐一查找;同一位置只保留最长匹配(上海虹桥 优先于 上海)
    private static func findStations(in text: String) -> [Hit] {
        var all: [Hit] = []
        for station in StationDirectory.shared.stations {
            var searchStart = text.startIndex
            while let range = text.range(of: station.n, range: searchStart..<text.endIndex) {
                all.append(Hit(range: range, text: station.n))
                searchStart = range.upperBound
            }
        }
        all.sort {
            $0.range.lowerBound == $1.range.lowerBound
                ? $0.text.count > $1.text.count
                : $0.range.lowerBound < $1.range.lowerBound
        }
        var hits: [Hit] = []
        var previous: String.Index?
        for hit in all {
            if let p = previous, hit.range.lowerBound == p { continue }
            hits.append(hit)
            previous = hit.range.lowerBound
        }
        return hits
    }

    /// 离车次号最近的价格(¥ 或 元 标记)
    private static func nearestPrice(in text: String, around position: String.Index) -> Double? {
        let hits = allMatches(of: "[¥￥]\\s*(\\d+(\\.\\d{1,2})?)|(\\d+(\\.\\d{1,2})?)\\s*元", in: text)
        guard let hit = nearest(hits, to: position, in: text) else { return nil }
        let digits = hit.text.filter { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    /// 就近识别 "05车04B号" 形态的车厢座位
    private static func parseCoachSeat(_ text: String, around position: String.Index) -> (coach: String, seat: String)? {
        let hits = allMatches(of: "(\\d{1,2})\\s*车\\s*([0-9]{1,3}[A-Z]?\\s*号?|[上下中]铺)", in: text)
        guard let hit = nearest(hits, to: position, in: text) else { return nil }
        let whole = String(text[hit.range])
        guard let r = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*车\\s*([0-9]{1,3}[A-Z]?\\s*号?|[上下中]铺)") else { return nil }
        if let m = r.firstMatch(in: whole, range: NSRange(whole.startIndex..., in: whole)),
           let cRange = Range(m.range(at: 1), in: whole),
           let sRange = Range(m.range(at: 2), in: whole) {
            return (String(whole[cRange]) + "车", String(whole[sRange]))
        }
        return nil
    }
}
