import SwiftUI
import SwiftData

/// 「同步」页:QQ 邮箱授权配置、手动/自动同步、候选票根确认导入
struct SyncView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MailCandidate.fetchedAt, order: .reverse) private var candidates: [MailCandidate]

    @ObservedObject private var engine = MailSyncEngine.shared
    @State private var email = ""
    @State private var authCode = ""
    @State private var ownerName = ""
    @State private var selectedCandidate: MailCandidate?
    @State private var lastShownEmail = ""
    @State private var confirmingImportAll = false

    private var pending: [MailCandidate] {
        candidates.filter { !$0.imported }
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                syncSection
                candidateSection
            }
            .navigationTitle("邮件同步")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadAccount()
                if ProcessInfo.processInfo.arguments.contains("-ImportAll") {
                    importAll()
                }
            }
            .confirmationDialog("全部导入?", isPresented: $confirmingImportAll, titleVisibility: .visible) {
                Button("导入 \(pending.count) 条") { importAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有待确认票根将按解析结果直接入库,之后可在票根页逐条编辑补充。")
            }
            .onChange(of: engine.lastSyncDate) { _, _ in }
        }
    }

    // MARK: 账号

    private var accountSection: some View {
        Section {
            TextField("QQ 邮箱,如 123456789@qq.com", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("授权码(16 位)", text: $authCode)
            TextField("乘车人姓名(只导入本人,如 张三)", text: $ownerName)
        } header: {
            Text("QQ 邮箱账号")
        } footer: {
            Text("在 QQ 邮箱网页版:设置 → 账户 → 开启「IMAP/SMTP 服务」→ 生成授权码,把授权码填到这里(不是 QQ 密码)。授权码保存在本机钥匙串,不会上传。填了乘车人姓名就只导入本人车票,家人票自动跳过。")
        }
    }

    // MARK: 同步

    private var syncSection: some View {
        Section {
            HStack {
                if engine.running {
                    ProgressView().padding(.trailing, 8)
                }
                Text(engine.statusText)
                    .foregroundColor(.secondary)
            }
            Button {
                saveAccountIfNeeded()
                Task { await engine.sync(context: modelContext) }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(engine.running ? "同步中…" : "立即同步")
                }
            }
            .disabled(engine.running || email.isEmpty || authCode.isEmpty)
            Button {
                confirmingImportAll = true
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text("全部导入(\(pending.count))")
                }
            }
            .disabled(pending.isEmpty)
            HStack {
                Text("上次同步")
                    .foregroundColor(.secondary)
                Spacer()
                if let last = engine.lastSyncDate {
                    Text(Fmt.dotDate.string(from: last) + " " + Fmt.clock.string(from: last))
                        .foregroundColor(.secondary)
                } else {
                    Text("从未").foregroundColor(.secondary)
                }
            }
        } header: {
            Text("同步")
        } footer: {
            Text("打开 App 时会自动增量同步(距上次同步超过 30 分钟)。邮件解析的候选票根需要你确认后才会入库。")
        }
    }

    // MARK: 候选列表

    private var candidateSection: some View {
        Section {
            if pending.isEmpty {
                Text("没有待导入的邮件票根")
                    .foregroundColor(.secondary)
            } else {
                ForEach(pending, id: \.id) { candidate in
                    Button {
                        selectedCandidate = candidate
                    } label: {
                        CandidateRow(candidate)
                    }
                }
                .onDelete(perform: deleteCandidates)
            }
        } header: {
            Text("待导入票根 \(pending.count)")
        }
    }

    private func CandidateRow(_ candidate: MailCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let trainNo = candidate.trainNo, !trainNo.isEmpty {
                    Text(trainNo)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.railRed))
                }
                if let date = candidate.date {
                    Text(Fmt.dotDate.string(from: date))
                        .font(.system(size: 12, weight: .medium))
                }
                Text(candidate.source)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
                Text(TicketInfo.stationText(candidate.fromStation))
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.railRed)
                Text(TicketInfo.stationText(candidate.toStation))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let seatClass = candidate.seatClass, !seatClass.isEmpty {
                    Text(seatClass).font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let price = candidate.price {
                    Text(candidate.priceText ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.railRed)
                }
            }
        }
    }

    // MARK: 行为

    private func loadAccount() {
        let stored = engine.storedEmail
        guard !stored.isEmpty else { return }
        if email.isEmpty || email == lastShownEmail {
            email = stored
        }
        lastShownEmail = stored
        ownerName = UserDefaults.standard.string(forKey: "mail.owner") ?? ""
    }

    private func saveAccountIfNeeded() {
        guard !email.isEmpty, !authCode.isEmpty else { return }
        engine.saveAccount(email: email, authCode: authCode)
        UserDefaults.standard.set(ownerName, forKey: "mail.owner")
    }

    private func deleteCandidates(at offsets: IndexSet) {
        let rows = pending
        for index in offsets {
            modelContext.delete(rows[index])
        }
        try? modelContext.save()
    }

    /// 批量导入:按解析结果直接建票根
    private func importAll() {
        let count = MailSyncEngine.importAllCandidates(context: modelContext)
        engine.statusText = "已批量导入 \(count) 条票根"
    }
}

extension MailCandidate {
    var priceText: String? {
        guard let p = price, p > 0 else { return nil }
        return p.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "¥%.0f", p)
            : String(format: "¥%.1f", p)
    }
}
