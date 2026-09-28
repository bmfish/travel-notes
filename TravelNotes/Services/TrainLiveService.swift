import Foundation

/// 车次当日运行信息的一站:检票口、出站口、候车室、晚点
struct TrainLiveStop: Hashable {
    let stationName: String
    /// 检票口原文,"--" 或空表示未公布
    let wicket: String
    /// 出站口原文
    let exit: String
    /// 候车室原文
    let waitingRoom: String
    /// 当前晚点分钟数(0 = 正点)
    let delayMinutes: Int

    /// 清理后的检票口语句:"6A、7A进站检票口" -> "6A、7A";未公布返回 nil
    var gateDisplay: String? {
        let raw = wicket.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != "--" else { return nil }
        return raw
            .replacingOccurrences(of: "进站检票口", with: "")
            .replacingOccurrences(of: "检票口", with: "")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "、, "))
    }
}

/// 车次当日运行信息(检票口/晚点),来自 12306 小程序公开接口,免登录
struct TrainLiveInfo: Hashable {
    let trainCode: String
    let date: Date
    let stops: [TrainLiveStop]

    /// 全列当前最大晚点分钟(0 = 正点)
    var maxDelay: Int { stops.map(\.delayMinutes).max() ?? 0 }

    func stop(at station: String?) -> TrainLiveStop? {
        guard let station else { return nil }
        return stops.first { TrainLiveService.looseMatch($0.stationName, station) }
    }
}

enum TrainLiveError: Error {
    case badResponse
}

/// 12306 小程序「车次运行信息」接口封装(免登录):当日车次的检票口、晚点等实时数据
final class TrainLiveService {
    static let shared = TrainLiveService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "MicroMessenger/8.0.43"]
        return URLSession(configuration: config)
    }()

    // 实时数据短时缓存,避免刷新时反复请求
    private var cache: [String: (info: TrainLiveInfo, at: Date)] = [:]
    private let cacheTTL: TimeInterval = 180
    private let queue = DispatchQueue(label: "rail.trainLive")

    /// 查询车次当日运行信息;仅出行当日有检票口/晚点数据
    func live(trainCode: String, date: Date) async throws -> TrainLiveInfo {
        let code = trainCode.trimmingCharacters(in: .whitespaces).uppercased()
        let day = Self.dayFormatter.string(from: date)
        let key = "\(code)|\(day)"
        if let hit = queue.sync(execute: { cache[key] }),
           Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.info
        }
        // 参数是 URL 查询串 + POST 空 body(必须带 Content-Length)
        let url = URL(string: "https://mobile.12306.cn/wxxcx/wechat/main/travelServiceQrcodeTrainInfo"
            + "?trainCode=\(code)&startDay=\(day)&startTime=&endDay=&endTime=")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        let (data, _) = try await session.data(for: request)
        let info = try Self.parse(data: data, trainCode: code, date: date)
        if !info.stops.isEmpty {
            queue.sync { cache[key] = (info, Date()) }
        }
        return info
    }

    /// 站名宽松比较:"郑州东" 与 "郑州东站" 视为同站
    static func looseMatch(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespaces), y = b.trimmingCharacters(in: .whitespaces)
        return x == y || x == y + "站" || x + "站" == y
    }

    // MARK: - 解析

    private static func parse(data: Data, trainCode: String, date: Date) throws -> TrainLiveInfo {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["data"] as? [String: Any],
              let detail = payload["trainDetail"] as? [String: Any],
              let rows = detail["stopTime"] as? [[String: Any]] else {
            throw TrainLiveError.badResponse
        }
        let stops = rows.map { row in
            TrainLiveStop(stationName: row["stationName"] as? String ?? "",
                          wicket: row["wicket"] as? String ?? "",
                          exit: row["exit"] as? String ?? "",
                          waitingRoom: row["waitingRoom"] as? String ?? "",
                          delayMinutes: int(row["ticketDelay"]))
        }
        return TrainLiveInfo(trainCode: trainCode, date: date, stops: stops)
    }

    private static func int(_ any: Any?) -> Int {
        switch any {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as String: return Int(v) ?? 0
        default: return 0
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
