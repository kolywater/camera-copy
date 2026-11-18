import SwiftUI
import AppKit

/// Sidebar section for the independent check. Nothing runs until the user clicks.
struct IndependentCheckSection: View {
    var model: AppModel
    @State private var showingReport = false

    private var check: IndependentCheck { model.independentCheck }

    var body: some View {
        Section("Independent check") {
            switch check.state {
            case .idle:
                idle
            case .running(let started):
                running(since: started)
            case .passed, .missing, .error:
                result
            }
        }
        .sheet(isPresented: $showingReport) { IndependentCheckReport(check: check) }
    }

    @ViewBuilder private var idle: some View {
        if let target = model.lastImport {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check this import with verify-card.sh, a separate script that fingerprints the card and the folder itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(target.card) → \((target.folder as NSString).lastPathComponent)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button { model.runIndependentCheckOnLastImport() } label: {
                    Text("Run Independent Check").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sourceEjected)
                .help(model.sourceEjected ? "Put the card back in to check it" : "Takes a few minutes for a full card")
            }
            .padding(.vertical, 2)
        }
        chooseOther
    }

    private func running(since started: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.headline)
                Spacer()
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(started))
                        .formatted(.time(pattern: .minuteSecond)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Stop") { check.stop() }.controlSize(.small)
            }
            if let progress = check.progress {
                // The script's own progress line, as a bar and in its own words.
                ProgressView(value: progress.fraction) {
                    Text(progress.stepText).font(.caption)
                }
                Text(progress.line)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text(check.latestLine.isEmpty ? "Starting verify-card.sh…" : check.latestLine)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(check.problem ?? check.latestLine)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(3).truncationMode(.middle)
                }
            }
            if check.state == .missing {
                ForEach(check.missingFiles.prefix(3), id: \.self) { line in
                    Text((line as NSString).lastPathComponent)
                        .font(.caption.monospaced()).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
                }
                if check.missingFiles.count > 3 {
                    Text("and \(check.missingFiles.count - 3) more").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Button("Show Report") { showingReport = true }
                if !check.cardPath.isEmpty {
                    Button("Run Again") { check.run(card: check.cardPath, folder: check.folderPath) }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        chooseOther
    }

    private var chooseOther: some View {
        Button("Check a Card and Folder…") { model.chooseAndRunIndependentCheck() }
            .buttonStyle(.link)
            .disabled(model.phase == .importing)
            .help("Check any card against a folder it was imported into, e.g. an earlier import")
    }

    private var icon: String {
        switch check.state {
        case .passed: return "checkmark.shield.fill"
        case .missing: return "xmark.shield.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch check.state {
        case .passed: return .green
        case .missing: return .red
        default: return .orange
        }
    }
    private var title: String {
        switch check.state {
        case .passed: return "Independent check passed"
        case .missing: return "Independent check found missing files"
        default: return check.problem?.contains("stopped") == true ? "Check stopped" : "The independent check couldn't finish"
        }
    }
}

/// Everything the script printed, sorted for reading, with the full output kept as is.
struct IndependentCheckReport: View {
    var check: IndependentCheck
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !check.missingFiles.isEmpty {
                        fileList("Missing from the folder (\(check.missingFiles.count))", check.missingFiles, color: .red)
                    }
                    if !check.extraFiles.isEmpty {
                        DisclosureGroup("Not copied, not a photo/video (\(check.extraFiles.count))") {
                            fileList(nil, check.extraFiles, color: .secondary)
                        }
                    }
                    DisclosureGroup("Full output") {
                        Text(check.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    about
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(copied ? "Copied" : "Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(check.output, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.title3.weight(.semibold)).foregroundStyle(headlineColor)
            // The script's own verdict line, word for word.
            Text(check.problem ?? check.latestLine).font(.callout.monospaced()).textSelection(.enabled)
            Text("Card: \(check.cardPath)\nFolder: \(check.folderPath)\nExit code: \(check.exitCode.map(String.init) ?? "none")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var headline: String {
        switch check.state {
        case .passed: return "Everything on the card is in the folder"
        case .missing: return "Some card files aren't in the folder"
        case .running: return "Checking…"
        default: return "The check couldn't finish"
        }
    }
    private var headlineColor: Color {
        switch check.state {
        case .passed: return .green
        case .missing: return .red
        case .error: return .orange
        default: return .primary
        }
    }

    private func fileList(_ title: String?, _ files: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.headline).foregroundStyle(color) }
            Text(files.joined(separator: "\n"))
                .font(.caption.monospaced()).foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("About this check").font(.caption.weight(.semibold))
            Text("Camera Copy runs verify-card.sh, a short script you can read, as a separate process. It fingerprints every file on the card and in the folder with Apple's shasum and uses none of Camera Copy's own code or checksums. It runs with its own minimal environment. Green needs exit code 0 and the script's own OK line; 1 means missing; anything else means it couldn't check.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Script SHA-256: \(check.scriptSHA256 ?? "unavailable")")
                .font(.caption2.monospaced()).textSelection(.enabled)
            Text("To match it, run shasum -a 256 tools/verify-card.sh in github.com/kolywater/camera-copy.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
