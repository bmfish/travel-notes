import Foundation
import SwiftData

/// 从订票邮件解析出的待确认票根
@Model
final class MailCandidate {
    var id: UUID = UUID()
    /// 邮件 Message-ID,用于去重
    var messageId: String = ""
    /// 乘车日期
    var date: Date?
    var trainNo: String?
    var fromStation: String?
    var toStation: String?
    /// 出发时刻文本(HH:mm),确认页再转 Date
    var departTimeText: String?
    var coach: String?
    var seat: String?
    var seatClass: String?
    var price: Double?
    /// 乘车人(从邮件解析)
    var passenger: String?
    /// 来源,如 12306
    var source: String = "12306"
    var imported: Bool = false
    var fetchedAt: Date = Date()

    init(messageId: String = "", date: Date? = nil, trainNo: String? = nil,
         fromStation: String? = nil, toStation: String? = nil,
         departTimeText: String? = nil, coach: String? = nil, seat: String? = nil,
         seatClass: String? = nil, price: Double? = nil, passenger: String? = nil,
         source: String = "12306") {
        self.id = UUID()
        self.messageId = messageId
        self.date = date
        self.trainNo = trainNo
        self.fromStation = fromStation
        self.toStation = toStation
        self.departTimeText = departTimeText
        self.coach = coach
        self.seat = seat
        self.seatClass = seatClass
        self.price = price
        self.passenger = passenger
        self.source = source
        self.fetchedAt = Date()
    }
}
