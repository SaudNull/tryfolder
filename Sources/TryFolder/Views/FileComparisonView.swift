import SwiftUI
import TryFolderCore

struct FileComparisonView: View {
    let model: AppModel
    let session: SessionRecord
    let review: ReviewRecord
    let change: FileChange
    @State private var starting: BoundedPreview.Content = .unavailable("Loading…")
    @State private var current: BoundedPreview.Content = .unavailable("Loading…")
    @State private var draft: BoundedPreview.Content = .unavailable("Loading…")
    @State private var originalReadAt: Date?
    @State private var showStarting = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(change.path).font(.headline).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if change.draft != nil {
                        Button { model.openDraftFile() } label: { Label("Open Live Draft File With…", systemImage: "arrow.up.forward.app") }
                            .help("Opens the current editable draft, which may differ from this sealed review")
                    }
                }
                if change.kind == .conflict {
                    Label("Both versions need attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout.weight(.medium))
                    Text(change.message ?? "The original and draft changed in incompatible ways.").font(.caption).foregroundStyle(.secondary)
                    Text("Keep the current original by leaving this change unselected. Keep as New Folder saves the sealed draft separately.")
                        .font(.caption)
                    Toggle("Show Starting Version", isOn: $showStarting).toggleStyle(.switch).controlSize(.small)
                } else if let message = change.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    metadata("Starting", change.baseline)
                    metadata("Original at Review", change.current)
                    metadata("Sealed draft", change.draft)
                }
                Text("Original preview shows its last read\(originalReadAt.map { " at " + $0.formatted(date: .omitted, time: .standard) } ?? ""). It is not continuously monitored. Metadata above belongs to the dated review.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            HSplitView {
                if change.kind == .conflict && showStarting {
                    PreviewPane(title: "Starting Version", content: starting, other: nil).frame(minWidth: 150)
                }
                PreviewPane(title: "Current Original · Last Read", content: current, other: draft).frame(minWidth: 150)
                PreviewPane(title: "Sealed Draft", content: draft, other: current).frame(minWidth: 150)
            }
        }
        .task(id: "\(review.id)-\(change.path)-\(session.state.rawValue)") {
            starting = .unavailable("Loading…"); current = .unavailable("Loading…"); draft = .unavailable("Loading…")
            originalReadAt = nil
            let baselineRoot = session.baselineURL, sourceRoot = session.sourceURL, snapshotRoot = review.snapshotURL, path = change.path
            let hasBaseline = change.baseline != nil, hasDraft = change.draft != nil
            let values = await Task.detached(priority: .userInitiated) {
                (hasBaseline ? BoundedPreview.load(root: baselineRoot, path: path) : .unavailable("Not present in starting version"),
                 BoundedPreview.load(root: sourceRoot, path: path),
                 hasDraft ? BoundedPreview.load(root: snapshotRoot, path: path) : .unavailable("Not present in sealed draft"))
            }.value
            guard !Task.isCancelled else { return }
            starting = values.0; current = values.1; draft = values.2
            originalReadAt = Date()
        }
    }
    private func metadata(_ title: String, _ entry: FileEntry?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold))
            if let entry {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)).font(.caption2)
                Text("Mode \(String(entry.mode, radix: 8)) · \(entry.fingerprint.prefix(10))").font(.caption2.monospaced()).lineLimit(1)
            } else { Text("Absent").font(.caption2) }
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreviewPane: View {
    let title: String
    let content: BoundedPreview.Content
    let other: BoundedPreview.Content?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            Divider()
            switch content {
            case let .text(lines, truncated):
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 32, alignment: .trailing)
                                Text(line.isEmpty ? " " : line).foregroundStyle(.primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 2).padding(.trailing, 10)
                                .background(different(line, at: index) ? Color.accentColor.opacity(0.10) : Color.clear)
                        }
                    }.padding(.vertical, 8)
                }
                Text(truncated ? "Bounded preview · first 256 KB / 3,000 lines" : "Line comparison · highlighted rows differ at this position")
                    .font(.caption2).foregroundStyle(.secondary).padding(8)
            case let .image(image):
                Image(nsImage: image).resizable().scaledToFit().padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .document(url):
                QuickLookView(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Quick Look · file-level comparison").font(.caption2).foregroundStyle(.secondary).padding(8)
            case let .unavailable(message):
                ContentUnavailableView { Label("No Preview", systemImage: "doc") } description: { Text(message) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func different(_ line: String, at index: Int) -> Bool {
        guard case let .text(otherLines, _) = other else { return false }
        return index >= otherLines.count || otherLines[index] != line
    }
}
