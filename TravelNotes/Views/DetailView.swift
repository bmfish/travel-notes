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

// MARK: - 全屏看图

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
