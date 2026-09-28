import SwiftUI
import SwiftData

struct DetailView: View {
    let entry: TicketEntry

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingEdit = false
    @State private var confirmingDelete = false
    @State private var photoViewer: PhotoViewerSheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                TicketFaceView(info: TicketInfo(entry: entry))
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.top, 8)

                if let note = entry.note, !note.isEmpty {
                    noteCard(note)
                }

                if entry.trainNo?.isEmpty == false {
                    StopsTimelineCard(entry: entry)
                }

                if !entry.photoFileNames.isEmpty {
                    photoGrid
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .background(Theme.paperBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEdit = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("删除票根", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddEditView(entry: entry)
        }
        .confirmationDialog("删除这张票根?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                PhotoStore.delete(entry.photoFileNames)
                modelContext.delete(entry)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("日记和照片会一并删除,无法恢复。")
        }
        .fullScreenCover(item: $photoViewer) { viewer in
            PhotoViewer(names: viewer.names, startIndex: viewer.startIndex)
        }
    }

    // MARK: 子视图

    private func noteCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日记")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.ticketGray)
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(Theme.ticketInk)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.8)))
    }

    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("照片 \(entry.photoFileNames.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.ticketGray)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Array(entry.photoFileNames.enumerated()), id: \.element) { index, name in
                    Button {
                        photoViewer = PhotoViewerSheet(names: entry.photoFileNames, startIndex: index)
                    } label: {
                        PhotoThumb(name: name)
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.8)))
    }
}

// MARK: - 经停时刻表

/// 12306 公开接口查的每站到发时刻;查过一次本地缓存
private struct StopsTimelineCard: View {
    let entry: TicketEntry

    @State private var stops: [TrainStop] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.railRed)
                    .frame(width: 4, height: 14)
                Text("经停时刻表")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(Theme.ticketInk)
                Spacer()
                if let trainNo = entry.trainNo {
                    Text(trainNo)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.railRed)
                }
            }

            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在查询 \(entry.trainNo ?? "车次") 时刻表…")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ticketGray)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else if failed {
                VStack(spacing: 8) {
                    Text("时刻表查询失败,可能是网络不通或车次已停运")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.ticketGray)
                    Button("重试") { Task { await load() } }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.railRed)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                timeline
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.8)))
        .task { await load() }
    }

    /// 竖排时间轴:左侧到发时刻,中间圆点线,右侧站名;票面区间高亮
    private var timeline: some View {
        let fromName = entry.fromStation ?? ""
        let toName = entry.toStation ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                let isBoard = Self.match(stop.stationName, fromName)
                let isAlight = Self.match(stop.stationName, toName)
                let highlight = isBoard || isAlight

                HStack(alignment: .top, spacing: 10) {
                    // 时刻列:始发只看开点,终到只看到点
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(displayTime(stop))
                            .font(.system(size: 13, weight: highlight ? .heavy : .medium,
                                          design: .monospaced))
                            .foregroundColor(highlight ? Theme.railRed : Theme.ticketInk.opacity(0.8))
                        if stop.stopoverText != "----", !stop.stopoverText.isEmpty {
                            Text("停\(stop.stopoverText)")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.ticketGray)
                        }
                    }
                    .frame(width: 52, alignment: .trailing)

                    // 轴线 + 圆点
                    VStack(spacing: 0) {
                        Circle()
                            .fill(highlight ? Theme.railRed : Theme.ticketGray.opacity(0.45))
                            .frame(width: highlight ? 9 : 6, height: highlight ? 9 : 6)
                            .padding(.top, 4)
                        if index < stops.count - 1 {
                            Rectangle()
                                .fill(Theme.ticketGray.opacity(0.25))
                                .frame(width: 2)
                                .frame(minHeight: 26)
                        }
                    }

                    // 站名列
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(stop.stationName)
                                .font(.system(size: 15, weight: highlight ? .heavy : .medium))
                                .foregroundColor(highlight ? Theme.ticketInk : Theme.ticketInk.opacity(0.75))
                            if isBoard {
                                tag("上车", Theme.routeGreen)
                            } else if isAlight {
                                tag("下车", Theme.railRed)
                            }
                        }
                        if index == 0 {
                            Text("始发站")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.ticketGray)
                        } else if index == stops.count - 1 {
                            Text("终到站")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.ticketGray)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .padding(.top, 2)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color))
    }

    /// 始发站显示开点,终到站显示到点,中间站显示到点
    private func displayTime(_ stop: TrainStop) -> String {
        if stop.arriveTime == "----" { return stop.departTime }
        return stop.arriveTime
    }

    /// 站名宽松比对(票面"上海虹桥" vs 时刻表"上海虹桥")
    private static func match(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && (a == b || a == b + "站" || a + "站" == b)
    }

    private func load() async {
        loading = true
        failed = false
        guard let trainNo = entry.trainNo, !trainNo.isEmpty,
              let from = entry.fromStation, let to = entry.toStation else {
            loading = false
            failed = true
            return
        }
        do {
            let result = try await TrainScheduleService.shared.stops(
                trainNo: trainNo, fromStation: from, toStation: to, date: entry.date)
            stops = result
            loading = false
            failed = result.isEmpty
        } catch {
            loading = false
            failed = true
        }
    }
}

struct PhotoViewerSheet: Identifiable {
    let id = UUID()
    let names: [String]
    let startIndex: Int
}

struct PhotoViewer: View {
    let names: [String]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(names: [String], startIndex: Int) {
        self.names = names
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    ZoomablePhoto(name: name)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}

struct ZoomablePhoto: View {
    let name: String

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in
                                scale = min(max(1, lastScale * v), 6)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.02 { reset() }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                if scale > 1 {
                                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                                    height: lastOffset.height + v.translation.height)
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                                if scale <= 1.02 { reset() }
                            }
                    )
                    .onTapGesture(count: 2) {
                        if scale > 1 {
                            reset()
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: name) {
            image = PhotoStore.load(name, maxPixel: 2000)
        }
    }

    private func reset() {
        withAnimation(.spring(duration: 0.25)) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }
}
