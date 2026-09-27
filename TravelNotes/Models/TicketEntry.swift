import Foundation
import SwiftData

enum TicketSkin: String, CaseIterable, Codable {
    case red
    case blue

    var displayName: String {
        switch self {
        case .red: return "复古红软纸票"
        case .blue: return "蓝色磁卡票"
        }
    }
}

/// 从车次号推断车型描述
enum TrainKind {
    static func describe(_ trainNo: String?) -> String? {
        guard let no = trainNo?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !no.isEmpty, let first = no.first else { return nil }
        switch first {
        case "G": return "高速动车"
        case "D": return "动车组"
        case "C": return "城际列车"
        case "K": return "快速列车"
        case "T": return "特快列车"
        case "Z": return "直达列车"
        case "L", "Y": return "临客列车"
        case "S": return "市郊列车"
        default:
            return no.allSatisfy(\.isNumber) ? "普速列车" : nil
        }
    }
}

@Model
final class TicketEntry {
    var id: UUID = UUID()
    /// 乘车日期(必填)
    var date: Date = Date()
    /// 开车时刻(可选)
    var departTime: Date?
    var trainNo: String?
    var fromStation: String?
    var toStation: String?
    var coach: String?
    var seat: String?
    var seatClass: String?
    var price: Double?
    var skinRaw: String = TicketSkin.blue.rawValue
    /// 日记正文
    var note: String?
    /// 沙盒 Documents/Photos/ 下的文件名
    var photoFileNames: [String] = []
    var createdAt: Date = Date()

    var skin: TicketSkin { TicketSkin(rawValue: skinRaw) ?? .blue }
    var kindDescription: String? { TrainKind.describe(trainNo) }

    init(date: Date = Date(),
         departTime: Date? = nil,
         trainNo: String? = nil,
         fromStation: String? = nil,
         toStation: String? = nil,
         coach: String? = nil,
         seat: String? = nil,
         seatClass: String? = nil,
         price: Double? = nil,
         skin: TicketSkin = .blue,
         note: String? = nil,
         photoFileNames: [String] = []) {
        self.date = date
        self.departTime = departTime
        self.trainNo = trainNo
        self.fromStation = fromStation
        self.toStation = toStation
        self.coach = coach
        self.seat = seat
        self.seatClass = seatClass
        self.price = price
        self.skinRaw = skin.rawValue
        self.note = note
        self.photoFileNames = photoFileNames
    }
}
