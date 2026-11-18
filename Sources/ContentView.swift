import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @AppStorage("gridCellSize") private var gridCellSize: Double = 90
    @State private var problemsOnly = false
    @State private var updater = Updater()

    private var shownFiles: [CardFile] {
        showingProblemsOnly ? model.cardFiles.filter(model.isProblem) : model.cardFiles
    }

    /// The filter only applies while its toggle is visible, so it can never hide everything with no way back.
    private var showingProblemsOnly: Bool {
        problemsOnly && model.phase == .done && !model.allVerified
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 380)
        } detail: {
            content
                .toolbar { toolbarContent }
                .onChange(of: model.phase) { problemsOnly = false }
        }
        .alert("Camera Copy", isPresented: Binding(get: { model.alertMessage != nil },
                                                   set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task {
            // Quiet check on launch: only speaks up if there is an update.
            await updater.check(userInitiated: false)
        }
        #if UPDATE_SELFTEST
        // Test builds only: do what a click on "Install and Relaunch" does, then close the alert as SwiftUI does.
        .task(id: updater.latest?.version) {
            guard updater.latest != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            updater.installButtonClicked()
            updater.showUpdateAlert = false
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .checkForUpdatesRequested)) { _ in
            Task { await updater.check(userInitiated: true) }
        }
        .alert("Update Available", isPresented: $updater.showUpdateAlert) {
            if model.phase == .importing {
                Button("Later", role: .cancel) {}
            } else {
                Button("Install and Relaunch") { updater.installButtonClicked() }
                Button("Later", role: .cancel) {}
            }
        } message: {
            if let info = updater.latest {
                let notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                let busy = model.phase == .importing ? "\n\nFinish the import first, then choose Check for Updates again." : ""
                Text("Camera Copy \(info.version) is available (you have \(updater.currentVersion)).\(busy)"
                     + (notes.isEmpty ? "" : "\n\n\(notes)"))
            }
        }
        .alert("Software Update", isPresented: Binding(
            get: { updateInfoMessage != nil },
            set: { if !$0 { updater.clearResult() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = updateInfoMessage { Text(message) }
        }
        .overlay {
            if updater.isBusy {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(updater.status == .installing ? "Installing update…" : "Downloading update…")
                            .font(.headline)
                        Text("Camera Copy will relaunch by itself.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    /// Result of a user-initiated check: "up to date" or why it failed.
    private var updateInfoMessage: String? {
        switch updater.status {
        case .upToDate: return "You're running the latest version (\(updater.currentVersion))."
        case .failed(let reason): return "Couldn't update.\n\n\(reason)"
        default: return nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if model.phase == .done && !model.allVerified {
                Toggle("Problems Only", isOn: $problemsOnly)
                    .toggleStyle(.button)
                    .help("Show only files that failed verification")
            }
            if viewMode == .grid {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 11))
                        .frame(width: 16, height: 16)
                    Slider(value: $gridCellSize, in: 40...240)
                        .labelsHidden()
                        .frame(width: 120)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 15))
                        .frame(width: 16, height: 16)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .help("Thumbnail size")
            }
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Grid", systemImage: "square.grid.3x3").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView("No Card Selected",
                                   systemImage: "sdcard",
                                   description: Text(model.scanError ?? "Plug in your camera's card, or choose a source folder."))
        case .scanning:
            ProgressView("Reading card…").frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.cardFiles.isEmpty {
                ContentUnavailableView("No Photos or Videos", systemImage: "photo.on.rectangle",
                                       description: Text("Nothing to import on \(model.sourcePath)."))
            } else if viewMode == .list {
                ComparisonList(model: model, files: shownFiles)
            } else {
                ComparisonGrid(model: model, files: shownFiles, cellSize: gridCellSize)
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Source") {
                HStack(spacing: 12) {
                    Image(systemName: model.sourceEjected ? "eject.circle" : "sdcard.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.sourceDisplayName).font(.headline)
                        Text(sourceDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { model.chooseSource() }
                        .help(model.sourcePath.isEmpty ? "Choose a card or folder" : model.sourcePath)
                        .disabled(model.phase == .importing)
                }
                .padding(.vertical, 2)
                if !model.skippedFiles.isEmpty {
                    SkippedFilesButton(files: model.skippedFiles)
                }
            }

            Section("Destination") {
                Picker("Copy to", selection: $model.destinationMode) {
                    Text("New Folder").tag(DestinationMode.newFolder)
                    Text("Existing Folder").tag(DestinationMode.existingFolder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Make a new folder, or add to one that already has some of this card")
                switch model.destinationMode {
                case .newFolder:
                    TextField("Name", text: $model.folderName, prompt: Text("Iceland Trip"))
                        .onSubmit { model.startImport() }
                    LabeledContent("Location") {
                        Button {
                            model.chooseParent()
                        } label: {
                            Label(model.parentDisplayName, systemImage: "folder")
                        }
                        .help("Saves to \(model.destinationPreview)")
                    }
                case .existingFolder:
                    LabeledContent("Folder") {
                        Button {
                            model.chooseExistingFolder()
                        } label: {
                            Label(model.existingFolderDisplayName, systemImage: "folder")
                        }
                        .help(model.existingFolderPath.isEmpty ? "Choose the folder to add to" : model.existingFolderPath)
                    }
                    ExistingFolderNote(model: model)
                }
            }
            .disabled(model.phase == .importing)

            if model.phase == .importing {
                Section("Importing") { ImportProgress(model: model) }
            } else if model.phase == .done {
                Section("Result") { ResultSummary(model: model) }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Group {
                if model.phase == .importing {
                    Button(role: .cancel) { model.cancelImport() } label: {
                        Text("Cancel Import").frame(maxWidth: .infinity)
                    }
                } else {
                    Button { model.startImport() } label: {
                        Text(importTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
                }
            }
            .controlSize(.large)
            .padding(16)
        }
    }

    private var importTitle: String {
        if model.cardFiles.isEmpty { return "Import" }
        guard model.destinationMode == .existingFolder, model.existingFolderError == nil else {
            return "Import \(Format.count(model.cardFiles.count)) Files"
        }
        let n = model.filesToCopyCount
        if n == 0 { return "Nothing New to Import" }
        return "Import \(Format.count(n)) New \(n == 1 ? "File" : "Files")"
    }

    private var sourceDetail: String {
        switch model.phase {
        case _ where model.sourceEjected:
            if model.phase == .done && model.allVerified { return "Ejected · safe to remove" }
            if model.phase == .importing || model.phase == .done { return "Card removed during import" }
            return "Ejected · plug in a card"
        case .idle: return model.scanError ?? "Plug in a card"
        case .scanning: return "Reading card…"
        default: return "\(Format.count(model.cardFiles.count)) items · \(Format.size(model.totalCardBytes))"
        }
    }
}

/// What an import into the chosen folder will do, before it starts.
struct ExistingFolderNote: View {
    var model: AppModel

    var body: some View {
        Group {
            if model.existingFolderPath.isEmpty {
                Text("Files the folder already has (same name and size) are skipped. Nothing in it is replaced.")
                    .foregroundStyle(.secondary)
            } else if let error = model.existingFolderError {
                Text(error).foregroundStyle(.red)
            } else if model.phase == .ready || model.phase == .done {
                let there = model.alreadyThere.count
                let new = model.filesToCopyCount
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(there == model.cardFiles.count
                         ? "The folder already has all \(Format.count(there)) files."
                         : "\(Format.count(new)) to copy, \(Format.count(there)) already there.")
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ImportProgress: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(model.bytesDone), total: Double(max(model.bytesTotal, 1)))
            if let timeLeft = model.timeLeftText {
                // Covers the whole job, verification included, so it reaches zero when the import ends.
                Text(timeLeft)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: timeLeft)
            }
            HStack {
                Text("\(Format.count(model.currentIndex)) of \(Format.count(model.runCount))")
                    .monospacedDigit()
                Spacer()
                Text(model.currentFileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ResultSummary: View {
    var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.allVerified ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .foregroundStyle(model.allVerified ? .green : .red)
                .font(.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.extraDestFiles.isEmpty {
                    Text("\(model.extraDestFiles.count) unexpected files in folder")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let err = model.manifestError {
                    Text("Couldn't save \(model.manifestFileName): \(err)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        if model.problemCount > 0 && model.destinationURL != nil {
            LabeledContent("Failed files") {
                Button("Retry \(Format.count(model.problemCount))") { model.retryFailed() }
                    .disabled(!model.canRetry)
                    .help(model.sourceEjected ? "Reinsert the card to retry" : "Copy and verify the failed files again")
            }
        }
        LabeledContent("Folder") {
            Button("Show in Finder") { model.revealDestination() }
        }
        LabeledContent("Card") {
            Button(model.sourceEjected ? "Ejected" : "Eject") { model.ejectCard() }
                .disabled(!model.allVerified || model.sourceEjected)
                .help(model.allVerified ? "Safely eject the card" : "Not every file verified")
        }
    }

    private var title: String {
        let there = model.alreadyThereCount
        if model.allVerified && there > 0 {
            return "\(Format.count(model.verifiedCount)) copied, \(Format.count(there)) already there"
        }
        if model.allVerified { return "All \(Format.count(model.cardFiles.count)) files verified" }
        if model.wasCancelled { return "Import cancelled" }
        return "\(Format.count(model.problemCount)) files have problems"
    }

    private var detail: String {
        if model.allVerified {
            let saved = model.manifestError == nil ? " Checksums saved to \(model.manifestFileName)." : ""
            return "Every copy's SHA-256 checksum matches two separate reads of the card.\(saved)"
        }
        let there = model.alreadyThereCount > 0 ? ", \(Format.count(model.alreadyThereCount)) already there" : ""
        return "\(Format.count(model.verifiedCount)) verified\(there), \(Format.count(model.problemCount)) not. Don't wipe this card."
    }
}

struct SkippedFilesButton: View {
    let files: [String]
    @State private var showing = false

    var body: some View {
        LabeledContent("Not copied") {
            Button("\(files.count) non-media files") { showing = true }
                .buttonStyle(.link)
                .popover(isPresented: $showing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On the card but not copied").font(.headline)
                        Text("Camera metadata and system files — not photos or videos.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(files, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                    }
                    .padding()
                    .frame(width: 420)
                }
        }
    }
}

/// Soft, borderless column labels that sit above each half of the comparison.
struct PaneTitles: View {
    var model: AppModel
    var gutter: CGFloat

    var body: some View {
        HStack(spacing: gutter) {
            title("On Card", detail: Format.count(model.cardFiles.count))
            title(model.destinationMode == .existingFolder ? "In Folder" : "Copied",
                  detail: model.destinationURL == nil ? "" : Format.count(model.destFiles.count))
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func title(_ t: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.title3.weight(.semibold))
            Text(detail).font(.title3).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Status icon

struct StatusIcon: View {
    let status: VerifyStatus?
    let hasDest: Bool
    let done: Bool

    var body: some View {
        Group {
            switch status {
            case .copying:
                ProgressView().controlSize(.small)
            case .verified(let hash) where hasDest || !done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .help("Verified — SHA-256 \(hash)")
            case .alreadyThere:
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    .help("Already in the folder (same name and size), so it wasn't copied")
            case .failed(let reason):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(reason)
            case .verified:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Missing from folder")
            default:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .font(.title3)
    }
}

// MARK: - List view

struct ComparisonList: View {
    var model: AppModel
    let files: [CardFile]

    var body: some View {
        ScrollView {
            PaneTitles(model: model, gutter: 44)
                .padding(.horizontal, 10)
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    ComparisonRow(file: file,
                                  dest: model.destFiles[file.id],
                                  status: model.statuses[file.id],
                                  imported: model.destinationURL != nil,
                                  done: model.phase == .done)
                    Divider()
                }
                if !model.extraDestFiles.isEmpty {
                    Text("In the folder but not on the card")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    ForEach(model.extraDestFiles, id: \.self) { d in
                        HStack(spacing: 0) {
                            Color.clear.frame(maxWidth: .infinity)
                            Color.clear.frame(width: 44)
                            FileCell(url: d.url, name: d.name, size: d.size, date: d.modified, subtitle: nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                    }
                }
            }
        }
    }
}

struct ComparisonRow: View {
    let file: CardFile
    let dest: DestFile?
    let status: VerifyStatus?
    let imported: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: 0) {
            FileCell(url: file.url, name: file.name, size: file.size, date: file.modified,
                     subtitle: file.relativePath)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusIcon(status: status, hasDest: dest != nil, done: done)
                .frame(width: 44)
            Group {
                if let dest {
                    FileCell(url: dest.url, name: dest.name, size: dest.size, date: dest.modified,
                             subtitle: dest.name == file.name ? nil : "renamed to avoid a duplicate name")
                } else {
                    HStack {
                        Text(done ? "Not in folder" : (imported ? "Waiting…" : "—"))
                            .foregroundStyle(done ? Color.red : Color.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 116)
        .background(done && (dest == nil || status?.isVerified != true) ? Color.red.opacity(0.08) : .clear)
    }
}

struct FileCell: View {
    let url: URL
    let name: String
    let size: Int64
    let date: Date
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: url, version: "\(size)|\(date.timeIntervalSince1970)")
                .frame(width: 150, height: 100)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(.body, design: .monospaced)).bold()
                Text(Format.size(size)).foregroundStyle(.secondary)
                Text(Format.date.string(from: date)).foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Grid view

struct ComparisonGrid: View {
    var model: AppModel
    let files: [CardFile]
    let cellSize: Double

    private let gutter: CGFloat = 24
    private let margin: CGFloat = 16
    private let spacing: CGFloat = 1

    private struct GridSection: Identifiable {
        let id: String
        let title: String
        let files: [CardFile]
    }

    private var sections: [GridSection] {
        let photos = files.filter { $0.kind == .photo }
        let videos = files.filter { $0.kind == .video }
        return [
            GridSection(id: "photos", title: "Photos · \(Format.count(photos.count))", files: photos),
            GridSection(id: "videos", title: "Videos · \(Format.count(videos.count))", files: videos),
        ].filter { !$0.files.isEmpty }
    }

    var body: some View {
        GeometryReader { geo in
            let half = max(1, (geo.size.width - gutter - margin * 2) / 2)
            let columns = max(1, Int(half / cellSize))
            let cell = floor((half - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            let done = model.phase == .done
            let imported = model.destinationURL != nil

            ScrollView {
                PaneTitles(model: model, gutter: gutter)
                    .padding(.horizontal, margin)
                LazyVStack(spacing: spacing) {
                    ForEach(sections) { section in
                        Section {
                            let rowCount = (section.files.count + columns - 1) / columns
                            ForEach(0..<rowCount, id: \.self) { row in
                                let slice = Array(section.files[(row * columns)..<min(section.files.count, (row + 1) * columns)])
                                HStack(spacing: 0) {
                                    HStack(spacing: spacing) {
                                        ForEach(slice) { file in
                                            GridTile(url: file.url, name: file.name, isVideo: file.kind == .video,
                                                     problem: false, missing: false, side: cell,
                                                     alreadyThere: model.statuses[file.id] == .alreadyThere,
                                                     version: "\(file.size)|\(file.modified.timeIntervalSince1970)")
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: half)
                                    Color.clear.frame(width: gutter)
                                    HStack(spacing: spacing) {
                                        ForEach(slice) { file in
                                            let dest = model.destFiles[file.id]
                                            GridTile(url: dest?.url, name: dest?.name ?? file.destName,
                                                     isVideo: file.kind == .video,
                                                     problem: done && model.isProblem(file),
                                                     missing: dest == nil, side: cell, empty: !imported,
                                                     version: dest.map { "\($0.size)|\($0.modified.timeIntervalSince1970)" } ?? "")
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: half)
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                    }
                }
                .padding(.horizontal, margin)
                .padding(.bottom, margin)
            }
            .overlay(alignment: .trailing) {
                if !imported {
                    ContentUnavailableView("Not Imported Yet", systemImage: "square.and.arrow.down",
                                           description: Text("Copies will appear here, lined up with the card."))
                        .frame(width: half)
                        .padding(.trailing, margin)
                }
            }
        }
    }
}

struct GridTile: View {
    let url: URL?
    let name: String
    let isVideo: Bool
    let problem: Bool
    let missing: Bool
    let side: CGFloat
    var alreadyThere: Bool = false
    var empty: Bool = false
    var version: String = ""

    var body: some View {
        // Fixed square frame first, image fills it via overlay, then clip — so every tile is a cropped square.
        Color.gray.opacity(empty ? 0 : 0.08)
            .frame(width: side, height: side)
            .overlay {
                if let url {
                    ThumbnailView(url: url, version: version, contentMode: .fill)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if isVideo, url != nil {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if alreadyThere {
                    // White ring keeps the badge readable on any photo, light or dark.
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: min(20, max(12, side * 0.16)), weight: .semibold))
                        .background(Circle().fill(.white).padding(1))
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .padding(max(3, side * 0.04))
                }
            }
            .overlay {
                if problem {
                    ZStack {
                        Color.red.opacity(missing ? 0.35 : 0.15)
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.white).font(.title3)
                    }
                    .border(Color.red, width: 2)
                }
            }
            .contentShape(Rectangle())
            .help(alreadyThere ? "\(name) is already in the folder" : name)
    }
}
