import Foundation

/// 经停站时刻表的一站
struct TrainStop: Identifiable, Hashable, Codable {
    var id: String { stationName + arriveTime + departTime }
    let stationName: String
    /// "----" 表示始发站无到达时刻
    let arriveTime: String
    /// "----" 表示终到站无出发时刻
    let departTime: String
    /// "3分钟" 或 "----"
    let stopoverText: String
}

enum TrainScheduleError: Error {
    case notFound
}

/// 12306 公开接口封装(免登录):电报码、车次内部编号、经停时刻表
final class TrainScheduleService {
    static let shared = TrainScheduleService()

    private let base = "https://kyfw.12306.cn/otn"
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            "Referer": "https://kyfw.12306.cn/otn/leftTicket/init"
        ]
        return URLSession(configuration: config)
    }()

    private var telecodes: [String: String]?
    private var bootstrapped = false
    private let trainNoCacheKey = "rail.trainNoCache"

    // MARK: - 对外接口

    /// 查询车次全程经停时刻表;结果按「车次+日期」缓存,历史日期查不到时按当前运行图兜底
    func stops(trainNo: String, fromStation: String, toStation: String, date: Date) async throws -> [TrainStop] {
        let cacheKey = "\(trainNo)|\(Self.dateFormatter.string(from: date))"
        if let cached = Self.loadStopsCache()[cacheKey], !cached.isEmpty {
            return cached
        }
        try await bootstrap()
        let codes = try await telecodeMap()
        guard let fromCode = lookup(fromStation, in: codes),
              let toCode = lookup(toStation, in: codes) else {
            throw TrainScheduleError.notFound
        }
        let internalNo = try await resolveTrainNo(trainNo: trainNo, fromCode: fromCode,
                                                  toCode: toCode, date: date)
        var rows = try await fetchStops(trainNo: internalNo, fromCode: fromCode,
                                        toCode: toCode, date: date)
        if rows.isEmpty {
            rows = try await fetchStops(trainNo: internalNo, fromCode: fromCode,
                                        toCode: toCode, date: Date())
        }
        if !rows.isEmpty {
            Self.saveStopsCache(key: cacheKey, stops: rows)
        }
        return rows
    }

    // MARK: - 经停表本地缓存(查过一次就不再走网络)

    private static func stopsCacheURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("train_stops_cache.json")
    }

    private static func loadStopsCache() -> [String: [TrainStop]] {
        guard let data = try? Data(contentsOf: stopsCacheURL()),
              let decoded = try? JSONDecoder().decode([String: [TrainStop]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveStopsCache(key: String, stops: [TrainStop]) {
        var cache = loadStopsCache()
        cache[key] = stops
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: stopsCacheURL(), options: .atomic)
        }
    }

    // MARK: - 经停站查询

    private func fetchStops(trainNo: String, fromCode: String, toCode: String,
                            date: Date) async throws -> [TrainStop] {
        let dateText = Self.dateFormatter.string(from: date)
        let url = URL(string: "\(base)/czxx/queryByTrainNo?train_no=\(trainNo)"
            + "&from_station_telecode=\(fromCode)&to_station_telecode=\(toCode)"
            + "&depart_date=\(dateText)")!
        let (data, _) = try await session.data(from: url)
        struct Response: Decodable {
            struct Payload: Decodable { let data: [Row]? }
            struct Row: Decodable {
                let station_name: String?
                let arrive_time: String?
                let start_time: String?
                let stopover_time: String?
            }
            let data: Payload?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.data?.data ?? []).map {
            TrainStop(stationName: $0.station_name ?? "",
                      arriveTime: $0.arrive_time ?? "----",
                      departTime: $0.start_time ?? "----",
                      stopoverText: $0.stopover_time ?? "----")
        }
    }

    // MARK: - 车次内部编号(G4098 -> 2400000G40980A 这类)

    private func resolveTrainNo(trainNo: String, fromCode: String, toCode: String,
                                date: Date) async throws -> String {
        if let cached = UserDefaults.standard.dictionary(forKey: trainNoCacheKey) as? [String: String],
           let hit = cached[trainNo] {
            return hit
        }
        // 余票接口只查得到未出行的日期:票面在未来用票面日期,否则往后找几周
        let cal = Calendar.current
        var candidates: [Date] = []
        if date > Date() { candidates.append(date) }
        for offset in [7, 14, 21, 28, 35, 42] {
            if let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) {
                candidates.append(d)
            }
        }
        for d in candidates {
            if let hit = try? await queryInternalTrainNo(trainNo: trainNo, fromCode: fromCode,
                                                         toCode: toCode, date: d), !hit.isEmpty {
                var cache = UserDefaults.standard.dictionary(forKey: trainNoCacheKey) as? [String: String] ?? [:]
                cache[trainNo] = hit
                UserDefaults.standard.set(cache, forKey: trainNoCacheKey)
                return hit
            }
        }
        throw TrainScheduleError.notFound
    }

    private func queryInternalTrainNo(trainNo: String, fromCode: String, toCode: String,
                                      date: Date) async throws -> String {
        let dateText = Self.dateFormatter.string(from: date)
        var path = "query"
        // 12306 会先返回 {"c_url":"leftTicket/queryG"} 提示切换端点
        for _ in 0..<2 {
            let url = URL(string: "\(base)/leftTicket/\(path)"
                + "?leftTicketDTO.train_date=\(dateText)&leftTicketDTO.from_station=\(fromCode)"
                + "&leftTicketDTO.to_station=\(toCode)&purpose_codes=ADULT")!
            let (data, _) = try await session.data(from: url)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let switchTo = obj["c_url"] as? String {
                path = switchTo.replacingOccurrences(of: "leftTicket/", with: "")
                continue
            }
            // result 每行是 | 分隔的字段,下标 2 为内部车次号,下标 3 为车次名
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = ((obj?["data"] as? [String: Any])?["result"] as? [String]) ?? []
            for row in rows {
                let fields = row.components(separatedBy: "|")
                if fields.count > 3, fields[3] == trainNo {
                    return fields[2]
                }
            }
            return ""
        }
        return ""
    }

    // MARK: - 电报码(站名 -> ZAF 这类三字码)

    private func telecodeMap() async throws -> [String: String] {
        if let telecodes { return telecodes }
        var map: [String: String] = [:]
        // 12306 全国站名表:每段 @缩写|站名|电报码|拼音|...
        let url = URL(string: "https://kyfw.12306.cn/otn/resources/js/framework/station_name.js")!
        let (data, _) = try await session.data(from: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        for seg in text.components(separatedBy: "@") {
            let parts = seg.components(separatedBy: "|")
            if parts.count > 2, !parts[1].isEmpty, !parts[2].isEmpty {
                map[parts[1]] = parts[2]
            }
        }
        telecodes = map
        return map
    }

    private func lookup(_ station: String, in codes: [String: String]) -> String? {
        let name = station.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = codes[name] { return code }
        if name.hasSuffix("站") { return codes[String(name.dropLast())] }
        return nil
    }

    private func bootstrap() async throws {
        guard !bootstrapped else { return }
        bootstrapped = true
        // 先访问一次首页拿 12306 的会话 cookie
        let url = URL(string: "\(base)/leftTicket/init")!
        _ = try? await session.data(from: url)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
