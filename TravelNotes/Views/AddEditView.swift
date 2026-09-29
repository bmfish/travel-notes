import SwiftUI
import SwiftData
import PhotosUI

struct AddEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建
    var entry: TicketEntry?
    /// 从邮件候选导入(nil = 普通新建/编辑)
    var candidate: MailCandidate?

    @State private var date = Date()
    @State private var includeTime = false
    @State private var departTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var trainNo = ""
    @State private var from = ""
    @State private var to = ""
    @State private var coach = ""
    @State private var seatNo = ""
    @State private var seatClass: String?
    @State private var priceText = ""
    @State private var skin: TicketSkin = .blue
    @State private var note = ""
    @State private var photoNames: [String] = []

    @State private var originalNames: [String] = []
    @State private var pendingNewNames: [String] = []
    @State private var removedOldNames: [String] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showValidation = false
    @State private var didPopulate = false

    static let seatClassOptions = ["二等座", "一等座", "商务座", "硬座", "软座", "硬卧", "软卧", "无座"]

    var body: some View {
        NavigationStack {
            Form {
                tripSection
                trainSection
                skinSection
                noteSection
                photoSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paperBackground.ignoresSafeArea())
            .listRowBackground(Theme.creamPaper)
            .listRowSeparatorTint(Theme.ticketGray.opacity(0.25))
            .tint(Theme.railBlue)
            // 日期/时间选择器走中文
            .environment(\.locale, .init(identifier: "zh_CN"))
            .navigationTitle(entry == nil ? (candidate == nil ? "记一笔" : "确认票根") : "编辑行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .alert("还差一点信息", isPresented: $showValidation) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("乘车日期必填,出发站和到达站至少填一个。")
            }
            .onAppear(perform: populate)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let name = PhotoStore.save(from: data) {
                            photoNames.append(name)
                            pendingNewNames.append(name)
                        }
                    }
                    pickerItems = []
                }
            }
        }
    }

    // MARK: 表单分区

    private var tripSection: some View {
        Section("行程") {
            StationField(label: "出发站", text: $from)
            StationField(label: "到达站", text: $to)
            DatePicker("乘车日期", selection: $date, displayedComponents: .date)
            Toggle("填写开车时刻", isOn: $includeTime.animation())
            if includeTime {
                DatePicker("开车时刻", selection: $departTime, displayedComponents: .hourAndMinute)
            }
        }
    }

    private var trainSection: some View {
        Section("车次") {
            TextField("车次号,如 G1024", text: $trainNo)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: trainNo) { _, v in
                    let up = v.uppercased()
                    if up != v { trainNo = up }
                }
            HStack {
                TextField("车厢,如 12车", text: $coach)
                Divider()
                TextField("座位,如 07A号", text: $seatNo)
            }
            Menu {
                Button("不填") { seatClass = nil }
                ForEach(Self.seatClassOptions, id: \.self) { option in
                    Button(option) { seatClass = option }
                }
            } label: {
                HStack {
                    Text("席别").foregroundColor(.secondary)
                    Spacer()
                    Text(seatClass ?? "不填")
                        .foregroundColor(seatClass == nil ? .secondary : .primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            TextField("票价", text: $priceText)
                .keyboardType(.decimalPad)
        }
    }

    private var skinSection: some View {
        Section("票面皮肤") {
            HStack(alignment: .top, spacing: 14) {
                skinPreview(.red)
                skinPreview(.blue)
            }
            .padding(.vertical, 6)
        }
    }

    private var noteSection: some View {
        Section("日记") {
            TextEditor(text: $note)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
        }
    }

    private var photoSection: some View {
        Section("照片") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                ForEach(photoNames, id: \.self) { name in
                    PhotoThumb(name: name)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                removePhoto(name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .offset(x: 6, y: -6)
                        }
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 9, matching: .images) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                        Text("从相册选")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 84, height: 84)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 票面预览

    private func skinPreview(_ s: TicketSkin) -> some View {
        let preview = TicketInfo(
            trainNo: trainNo.isEmpty ? "G1024" : trainNo,
            from: from.isEmpty ? "杭州东" : from,
            to: to.isEmpty ? "上海虹桥" : to,
            date: date,
            departTime: includeTime ? departTime : nil,
            coach: coach.isEmpty ? nil : coach,
            seat: seatNo.isEmpty ? nil : seatNo,
            seatClass: seatClass,
            price: Double(priceText),
            skin: s
        )
        return Button {
            skin = s
        } label: {
            VStack(spacing: 8) {
                TicketFaceView(info: preview, punchColor: Color(uiColor: .secondarySystemGroupedBackground))
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                HStack(spacing: 4) {
                    Image(systemName: skin == s ? "checkmark.circle.fill" : "circle")
                    Text(s.displayName).font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(skin == s ? Theme.railRedDeep : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 行为

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        if let e = entry {
            date = e.date
            if let t = e.departTime {
                includeTime = true
                departTime = t
            }
            trainNo = e.trainNo ?? ""
            from = e.fromStation ?? ""
            to = e.toStation ?? ""
            coach = e.coach ?? ""
            seatNo = e.seat ?? ""
            seatClass = e.seatClass
            if let p = e.price {
                priceText = p.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", p)
                    : String(format: "%.1f", p)
            }
            skin = e.skin
            note = e.note ?? ""
            photoNames = e.photoFileNames
            originalNames = e.photoFileNames
            return
        }
        if let c = candidate {
            date = c.date ?? Date()
            if let timeText = c.departTimeText {
                let parts = timeText.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2 {
                    includeTime = true
                    departTime = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) ?? date
                }
            }
            trainNo = c.trainNo ?? ""
            from = c.fromStation ?? ""
            to = c.toStation ?? ""
            coach = c.coach ?? ""
            seatNo = c.seat ?? ""
            seatClass = c.seatClass
            if let p = c.price {
                priceText = p.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", p)
                    : String(format: "%.1f", p)
            }
        }
    }

    private func removePhoto(_ name: String) {
        photoNames.removeAll { $0 == name }
        if pendingNewNames.contains(name) {
            PhotoStore.delete([name])
            pendingNewNames.removeAll { $0 == name }
        } else {
            removedOldNames.append(name)
        }
    }

    private func cancel() {
        PhotoStore.delete(pendingNewNames)
        dismiss()
    }

    private func save() {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty || !t.isEmpty else {
            showValidation = true
            return
        }

        let target: TicketEntry
        if let e = entry {
            target = e
        } else {
            target = TicketEntry(date: date)
            modelContext.insert(target)
        }
        target.date = date
        target.departTime = includeTime ? departTime : nil
        let no = trainNo.trimmingCharacters(in: .whitespacesAndNewlines)
        target.trainNo = no.isEmpty ? nil : no.uppercased()
        target.fromStation = f.isEmpty ? nil : f
        target.toStation = t.isEmpty ? nil : t
        let c = coach.trimmingCharacters(in: .whitespacesAndNewlines)
        target.coach = c.isEmpty ? nil : c
        let s = seatNo.trimmingCharacters(in: .whitespacesAndNewlines)
        target.seat = s.isEmpty ? nil : s
        target.seatClass = seatClass
        let price = Double(priceText.trimmingCharacters(in: .whitespacesAndNewlines))
        target.price = price
        target.skinRaw = skin.rawValue
        target.note = note.isEmpty ? nil : note
        target.photoFileNames = photoNames

        PhotoStore.delete(removedOldNames)
        if let candidate {
            candidate.imported = true
        }
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - 站名输入(带补全)

struct StationField: View {
    let label: String
    @Binding var text: String

    @FocusState private var focused: Bool
    @State private var showSuggestions = false

    private var suggestions: [Station] {
        StationDirectory.shared.suggest(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).foregroundColor(.secondary)
                Spacer()
                TextField("如 杭州东", text: $text)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit { showSuggestions = false }
            }
            .padding(.vertical, 8)

            if showSuggestions && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { s in
                        Button {
                            text = s.n
                            showSuggestions = false
                            focused = false
                        } label: {
                            HStack {
                                Text(s.n).font(.system(size: 14, weight: .medium))
                                Text(s.c).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: focused) { _, f in
            if !f {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !focused { showSuggestions = false }
                }
            } else if !text.isEmpty {
                showSuggestions = true
            }
        }
        .onChange(of: text) { _, v in
            showSuggestions = focused && !v.isEmpty
        }
    }
}

// MARK: - 照片缩略图

struct PhotoThumb: View {
    let name: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.08)
                    .overlay(ProgressView())
            }
        }
        .task(id: name) {
            image = PhotoStore.load(name, maxPixel: 260)
        }
    }
}
