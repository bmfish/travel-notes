import Foundation
import SwiftData

/// 邮件同步引擎:IMAP 拉取订票邮件 → 解析候选票根 → 用户确认后入库
@MainActor
final class MailSyncEngine: ObservableObject {
    static let shared = MailSyncEngine()

    static let keychainService = "com.bmfish.TravelNotes.mail"
    private static let emailKey = "mail.email"
    private static let lastSyncKey = "mail.lastSync"
    /// QQ 邮箱 IMAP
    static let imapHost = "imap.qq.com"
    static let imapPort: UInt16 = 993

    @Published var running = false
    @Published var statusText = "未同步"
    @Published var lastSyncDate: Date? = UserDefaults.standard.object(forKey: MailSyncEngine.lastSyncKey) as? Date

    var storedEmail: String {
        UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
    }

    var hasCredentials: Bool {
        !storedEmail.isEmpty && Keychain.get(service: Self.keychainService, account: storedEmail) != nil
    }

    func saveAccount(email: String, authCode: String) {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        UserDefaults.standard.set(normalized, forKey: Self.emailKey)
        Keychain.set(authCode, service: Self.keychainService, account: normalized)
    }

    func clearAccount() {
        let email = storedEmail
        if !email.isEmpty { Keychain.delete(service: Self.keychainService, account: email) }
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        lastSyncDate = nil
        statusText = "未同步"
    }

    /// 打开 App 时自动同步:已配置且距上次同步超过 30 分钟
    func autoSyncIfNeeded(context: ModelContext) {
        let debug = ProcessInfo.processInfo.arguments.contains("-MailUser")
        if debug { Self.trace("autoSync: hasCred=\(hasCredentials) running=\(running) last=\(lastSyncDate.map { "\($0)" } ?? "nil")") }
        guard hasCredentials, !running else { return }
        if let last = lastSyncDate, Date().timeIntervalSince(last) < 30 * 60 { return }
        if debug { Self.trace("autoSync: starting sync") }
        Task { await sync(context: context) }
    }

    static func trace(_ line: String) {
        guard ProcessInfo.processInfo.arguments.contains("-MailUser") else { return }
        let stamped = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/tn_trace.log") {
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: URL(fileURLWithPath: "/tmp/tn_trace.log"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: 同步主流程

    func sync(context: ModelContext) async {
        guard !running else { return }
        let email = storedEmail
        guard let authCode = Keychain.get(service: Self.keychainService, account: email), !email.isEmpty else {
            statusText = "请先填写邮箱和授权码"
            return
        }

        running = true
        defer { running = false }
        Self.trace("sync: begin")
        do {
            statusText = "连接 \(Self.imapHost)…"
            Self.trace("sync: connecting")
            let client = IMAPClient()
            try await client.connect(host: Self.imapHost, port: Self.imapPort)
            defer { client.disconnect() }

            statusText = "登录邮箱…"
            // QQ 邮箱要求在登录前发送 ID 命令表明客户端身份
            _ = try await client.command("ID (\"name\" \"TrainTicketDiary\" \"version\" \"1.0\")")
            _ = try await client.command("LOGIN \"\(Self.escape(email))\" \"\(Self.escape(authCode))\"")

            statusText = "打开收件箱…"
            _ = try await client.command("SELECT INBOX")

            let since = lastSyncDate ?? Calendar.current.date(byAdding: .day, value: -3650, to: Date())!
            statusText = "搜索订票邮件…"
            let searchRecords = try await client.command("UID SEARCH SINCE \(since) FROM \"12306\"")
            let uids = Self.parseSearchRecords(searchRecords)

            guard !uids.isEmpty else {
                statusText = "没有找到新的订票邮件"
                markSynced()
                return
            }

            statusText = "拉取 \(uids.count) 封邮件…"
            var doneCount = 0
            let known = Self.existingMessageIDs(context: context)

            // 阶段一:批量拉取所有邮件
            struct FetchedMail {
                let uid: String
                let subject: String
                let bodyText: String
                let orderNumber: String?
                let isRefund: Bool
                let isChange: Bool
            }
            var mails: [FetchedMail] = []
            for chunk in Self.chunked(uids, size: 20) {
                let query = chunk.joined(separator: ",")
                let records = try await client.command("UID FETCH \(query) (BODY.PEEK[])", timeout: 90)
                doneCount += chunk.count
                statusText = "拉取邮件 \(doneCount)/\(uids.count)…"
                Self.trace("batch \(doneCount)/\(uids.count)")
                for record in records where record.text.contains("FETCH") {
                    guard let raw = record.literals.first else { continue }
                    let messageId = Self.extractHeader("message-id", raw: raw) ?? "raw-\(record.text.prefix(24))"
                    guard !known.contains(messageId) else { continue }
                    let subject = MIME.decodeEncodedWords(Self.extractHeader("subject", raw: raw) ?? "")
                    let from = MIME.decodeEncodedWords(Self.extractHeader("from", raw: raw) ?? "")
                    // 退票/退单/改签邮件也要收集(分别用于退票集合与改签原票作废)
                    let isRefund = subject.contains("退票") || subject.contains("退单")
                    let isChange = subject.contains("改签")
                    guard isRefund || isChange || TicketMailParser.looksLikeTicketMail(from: from, subject: subject) else { continue }
                    let bodyText = MIME.stripHTML(MIME.extractBody(raw: raw))
                    let uid = Self.extractUID(record.text) ?? "uid-\(doneCount)-\(mails.count)"
                    mails.append(FetchedMail(uid: uid, subject: subject, bodyText: bodyText,
                                             orderNumber: Self.extractOrderNumber(bodyText),
                                             isRefund: isRefund, isChange: isChange))
                }
            }
            mails.sort { (Int($0.uid) ?? 0) < (Int($1.uid) ?? 0) }

            let ownerSetting = UserDefaults.standard.string(forKey: "mail.owner")
            let owner = (ownerSetting?.isEmpty == false) ? ownerSetting : nil

            // 阶段二:退票/退单邮件 → 已退票行程集合
            var refundKeys = Set<String>()
            for mail in mails where mail.isRefund {
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner) {
                    refundKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                   to: ticket.toStation, date: ticket.date))
                }
            }
            Self.trace("refund keys=\(refundKeys.count)")

            // 阶段三:改签处理 —— 同一订单只保留最后一次改签的新票,改签前的原票作废
            var lastChangeByOrder: [String: FetchedMail] = [:]
            for mail in mails where mail.isChange {
                if let order = mail.orderNumber {
                    lastChangeByOrder[order] = mail
                }
            }
            var changeValidKeys = Set<String>()
            for (order, mail) in lastChangeByOrder {
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner) {
                    changeValidKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                        to: ticket.toStation, date: ticket.date))
                }
            }
            var invalidatedKeys = Set<String>()
            for mail in mails where !mail.isChange && !mail.isRefund {
                // 该订单后来改签过,这封邮件描述的是改签前的原票 → 作废
                guard let order = mail.orderNumber, lastChangeByOrder[order] != nil else { continue }
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner) {
                    invalidatedKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                        to: ticket.toStation, date: ticket.date))
                }
            }
            Self.trace("change orders=\(lastChangeByOrder.count) invalidated=\(invalidatedKeys.count) valid=\(changeValidKeys.count)")

            // 阶段四:购票/改签/候补兑现邮件 → 候选票根
            var newCount = 0
            var knownTripKeys = Self.existingTripKeys(context: context)
            for mail in mails {
                guard !mail.isRefund else { continue }
                if mail.isChange {
                    // 同订单多次改签,只有最后一次的新票有效
                    guard let order = mail.orderNumber, lastChangeByOrder[order]?.uid == mail.uid else { continue }
                }
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: mail.bodyText, owner: owner) {
                    let tripKey = Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                               to: ticket.toStation, date: ticket.date)
                    guard !knownTripKeys.contains(tripKey) else { continue }
                    guard !refundKeys.contains(tripKey) else { continue }
                    if invalidatedKeys.contains(tripKey) && !changeValidKeys.contains(tripKey) { continue }
                    knownTripKeys.insert(tripKey)
                    let candidate = MailCandidate(
                        messageId: "mid-\(tripKey)",
                        date: ticket.date,
                        trainNo: ticket.trainNo,
                        fromStation: ticket.fromStation,
                        toStation: ticket.toStation,
                        departTimeText: ticket.departTimeText,
                        coach: ticket.coach,
                        seat: ticket.seat,
                        seatClass: ticket.seatClass,
                        price: ticket.price,
                        passenger: ticket.passenger
                    )
                    context.insert(candidate)
                    newCount += 1
                }
                try? context.save()
            }
            markSynced()
            statusText = newCount > 0 ? "同步完成,新增 \(newCount) 条待确认票根" : "同步完成,没有新的候选票根"
        } catch {
            statusText = "同步失败:\(error.localizedDescription)"
        }
    }

    // MARK: 自检(仅 -MailSyncTest 启动参数;支持本地 mock 或真实 QQ 邮箱)

    static func runSelfTestIfNeeded() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-MailSyncTest") else { return }
        var lines: [String] = []
        do {
            let host = Self.value(of: "-MailHost", in: args) ?? "imap.qq.com"
            let defaultPort = host == "127.0.0.1" ? "8025" : "993"
            let port = UInt16(Self.value(of: "-MailPort", in: args) ?? defaultPort) ?? 993
            let useTLS = host != "127.0.0.1"
            let user = Self.value(of: "-MailUser", in: args) ?? "test@qq.com"
            let pass = Self.value(of: "-MailPass", in: args) ?? "authcode123"
            let since = Self.value(of: "-MailSince", in: args)
                ?? Self.imapDate(Calendar.current.date(byAdding: .day, value: -3650, to: Date())!)

            let client = IMAPClient()
            try await client.connect(host: host, port: port, useTLS: useTLS)
            lines.append("connected host=\(host) tls=\(useTLS)")
            _ = try await client.command("ID (\"name\" \"TrainTicketDiary\" \"version\" \"1.0\")")
            _ = try await client.command("LOGIN \"\(Self.escape(user))\" \"\(Self.escape(pass))\"")
            lines.append("login ok")
            _ = try await client.command("SELECT INBOX")
            let search = try await client.command("UID SEARCH SINCE \(since) FROM \"12306\"")
            let uids = Self.parseSearchRecords(search)
            lines.append("uids=\(uids.count)")
            for uid in uids {
                let records = try await client.command("UID FETCH \(uid) (BODY.PEEK[])", timeout: 90)
                guard let record = records.first(where: { $0.text.contains("FETCH") }),
                      let raw = record.literals.first else { continue }
                let subject = MIME.decodeEncodedWords(Self.extractHeader("subject", raw: raw) ?? "")
                let from = MIME.decodeEncodedWords(Self.extractHeader("from", raw: raw) ?? "")
                lines.append("--- uid=\(uid) subject=\(subject)")
                let text = MIME.stripHTML(MIME.extractBody(raw: raw))
                if subject.contains("改签") {
                    lines.append("GSIGN_START uid=\(uid)")
                    for chunk in text.chunks(ofLength: 260) { lines.append("GS|\(chunk)") }
                }
                let tickets = TicketMailParser.parse(subject: subject, bodyText: text)
                lines.append("    parsed=\(tickets.count)")
                for t in tickets {
                    lines.append("    \(t.trainNo ?? "?") \(t.fromStation ?? "?")→\(t.toStation ?? "?") \(t.date.map { Fmt.dotDate.string(from: $0) } ?? "?") \(t.seatClass ?? "?") \(t.price.map { String($0) } ?? "?")")
                    if let fromStation = t.fromStation,
                       let range = text.range(of: fromStation) {
                        let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
                        let end = text.index(range.lowerBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
                        lines.append("    WIN|\(text[start..<end])")
                    }
                    if (t.toStation?.contains("香港") ?? false) || (t.fromStation?.contains("香港") ?? false),
                       let range = text.range(of: "香港") {
                        let start = text.index(range.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
                        let end = text.index(range.lowerBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
                        lines.append("    HK|\(text[start..<end])")
                    }
                }
            }
            client.disconnect()
        } catch {
            lines.append("ERROR: \(error.localizedDescription)")
        }
        try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/tn_sync.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func value(of key: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: 工具

    private func markSynced() {
        lastSyncDate = Date()
        UserDefaults.standard.set(Date(), forKey: Self.lastSyncKey)
    }

    private static func existingMessageIDs(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<MailCandidate>()
        return (try? context.fetch(descriptor).map(\.messageId))?.reduce(into: Set()) { $0.insert($1) } ?? []
    }

    /// 跨邮件内容去重:同一车次+区间+日期只保留一条候选
    private static func existingTripKeys(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<MailCandidate>()
        let all = (try? context.fetch(descriptor)) ?? []
        return Set(all.map { tripKey(trainNo: $0.trainNo, from: $0.fromStation, to: $0.toStation, date: $0.date) })
    }

    static func tripKey(trainNo: String?, from: String?, to: String?, date: Date?) -> String {
        let dateText = date.map { Fmt.dotDate.string(from: $0) } ?? "?"
        return "\(trainNo ?? "?")|\(from ?? "?")|\(to ?? "?")|\(dateText)"
    }

    /// 批量导入:所有未导入候选按解析结果直接建票根,返回导入数量
    @MainActor
    static func importAllCandidates(context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<MailCandidate>()
        let pending = ((try? context.fetch(descriptor)) ?? []).filter { !$0.imported }
        var count = 0
        for candidate in pending {
            var departTime: Date?
            if let timeText = candidate.departTimeText {
                let parts = timeText.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2 {
                    departTime = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0,
                                                       of: candidate.date ?? Date())
                }
            }
            let entry = TicketEntry(
                date: candidate.date ?? Date(),
                departTime: departTime,
                trainNo: candidate.trainNo,
                fromStation: candidate.fromStation,
                toStation: candidate.toStation,
                coach: candidate.coach,
                seat: candidate.seat,
                seatClass: candidate.seatClass,
                price: candidate.price,
                skin: .blue
            )
            entry.passenger = candidate.passenger
            context.insert(entry)
            candidate.imported = true
            count += 1
        }
        try? context.save()
        return count
    }

    /// 从正文提取 12306 订单号码,用于关联改签前后的邮件
    static func extractOrderNumber(_ bodyText: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "订单号码\\s*([A-Z0-9]{6,16})") else { return nil }
        guard let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
              let range = Range(match.range(at: 1), in: bodyText) else { return nil }
        return String(bodyText[range])
    }

    /// 从 FETCH 响应头里取 UID
    static func extractUID(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "UID (\\d+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func chunked(_ array: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }

    /// IMAP quoted string 转义
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// IMAP 日期:dd-Mon-yyyy
    static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date).uppercased()
    }

    /// 从 "UID SEARCH 101 102" 记录中取出 UID 列表
    static func parseSearchRecords(_ records: [IMAPRecord]) -> [String] {
        guard let search = records.first(where: { $0.text.hasPrefix("* SEARCH") }) else { return [] }
        return search.text
            .split(separator: " ")
            .dropFirst(2)
            .filter { $0.allSatisfy(\.isNumber) }
            .map(String.init)
    }

    /// 从原始邮件中提取单个头部字段(先做折叠行展开)
    static func extractHeader(_ name: String, raw: Data) -> String? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<headerEnd.lowerBound)
        let headers = String(decoding: headerData, as: UTF8.self)
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")
        for line in headers.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.hasPrefix(name + ":") {
                return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
