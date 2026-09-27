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
                let subject: String
                let raw: Data
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
                    // 退票/退单邮件也要收集(用于建立已退票行程集合)
                    let isRefund = subject.contains("退票") || subject.contains("退单")
                    guard isRefund || TicketMailParser.looksLikeTicketMail(from: from, subject: subject) else { continue }
                    mails.append(FetchedMail(subject: subject, raw: raw))
                }
            }

            let ownerSetting = UserDefaults.standard.string(forKey: "mail.owner")
            let owner = (ownerSetting?.isEmpty == false) ? ownerSetting : nil

            // 阶段二:退票/退单邮件 → 已退票行程集合
            var refundKeys = Set<String>()
            for mail in mails where mail.subject.contains("退票") || mail.subject.contains("退单") {
                let text = MIME.stripHTML(MIME.extractBody(raw: mail.raw))
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: text, owner: owner) {
                    refundKeys.insert(Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                                   to: ticket.toStation, date: ticket.date))
                }
            }
            Self.trace("refund keys=\(refundKeys.count)")

            // 阶段三:购票/改签/候补兑现邮件 → 候选票根(跳过已退票行程)
            var newCount = 0
            var knownTripKeys = Self.existingTripKeys(context: context)
            for mail in mails {
                guard !mail.subject.contains("退票"), !mail.subject.contains("退单") else { continue }
                let bodyText = MIME.stripHTML(MIME.extractBody(raw: mail.raw))
                for ticket in TicketMailParser.parse(subject: mail.subject, bodyText: bodyText, owner: owner) {
                    let tripKey = Self.tripKey(trainNo: ticket.trainNo, from: ticket.fromStation,
                                               to: ticket.toStation, date: ticket.date)
                    guard !knownTripKeys.contains(tripKey) else { continue }
                    guard !refundKeys.contains(tripKey) else { continue }
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
