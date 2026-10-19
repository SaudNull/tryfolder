import SwiftUI
import TryFolderCore

struct ReviewView: View {
    @Bindable var model: AppModel
    let session: SessionRecord
    let review: ReviewRecord
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Sealed Review", systemImage: "checkmark.seal").font(.headline)
                    Text(review.createdAt, format: .dateTime.month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.selectedPaths.count) selected").font(.caption).foregroundStyle(.secondary)
                }
                Text("This review contains captured draft bytes. Refresh Review to include newer edits. Keep exports the whole sealed draft; file selections control Apply only.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    summary(.added, "Added")
                    summary(.edited, "Edited")
                    summary(.removed, "Removed")
                    summary(.conflict, "Conflicts")
                    Spacer()
                }
                HStack(spacing: 7) {
                    Image(systemName: review.sourceAvailable ? (review.sourceUnchanged ? "checkmark.circle" : "exclamationmark.triangle") : "externaldrive.badge.exclamationmark")
                    Text(observation).font(.caption)
                }.foregroundStyle(review.sourceUnchanged && review.sourceAvailable ? Color.secondary : Color.orange)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Filter", selection: $model.filter) {
                            Text("All Changes").tag(nil as ChangeKind?)
                            ForEach(ChangeKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }.labelsHidden()
                        Menu {
                            Button("Select Applicable Changes") { model.selectedPaths = Set(review.changes.filter(\.canApply).map(\.path)) }
                            Button("Deselect All · Keep Originals") { model.selectedPaths = [] }
                        } label: { Image(systemName: "checklist") }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(10)
                    TextField("Filter files", text: $model.search).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 10)
                    List(selection: $model.selectedFile) {
                        ForEach(model.changes) { change in
                            HStack(spacing: 8) {
                                Toggle("Select \(change.path)", isOn: Binding(get: { model.selectedPaths.contains(change.path) }, set: { selected in
                                    if selected { model.selectedPaths.insert(change.path) } else { model.selectedPaths.remove(change.path) }
                                })).labelsHidden().toggleStyle(.checkbox).disabled(!change.canApply)
                                Image(systemName: change.kind.icon).foregroundStyle(change.kind.color)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(change.path).lineLimit(2)
                                    Text(change.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4).tag(change.path)
                            .help(change.path)
                        }
                    }.listStyle(.inset)
                    if model.changes.isEmpty { Text("No files match this filter.").font(.caption).foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
                if let change = model.currentChange {
                    FileComparisonView(model: model, session: session, review: review, change: change)
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Select a file to compare", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    private var observation: String {
        let when = review.createdAt.formatted(date: .omitted, time: .standard)
        let status = !review.sourceAvailable ? "Original was unavailable" : review.sourceUnchanged ? "Original matched its starting version" : "Original changes were observed"
        return "\(status) at \(when)." + (model.originalObservationStale ? " Refresh to check again." : " This is a completed check, not live monitoring.")
    }
    private func summary(_ kind: ChangeKind, _ name: String) -> some View {
        Label("\(review.changes.filter { $0.kind == kind }.count) \(name)", systemImage: kind.icon)
            .font(.caption.weight(.medium)).foregroundStyle(kind.color)
    }
}

extension ChangeKind {
    var title: String {
        switch self {
        case .added: "Added"
        case .edited: "Edited"
        case .removed: "Removed"
        case .sourceOnly: "Original Only"
        case .identical: "Same Result"
        case .conflict: "Conflict"
        }
    }
    var icon: String {
        switch self {
        case .added: "plus.circle"
        case .edited: "pencil.circle"
        case .removed: "minus.circle"
        case .sourceOnly: "folder.badge.exclamationmark"
        case .identical: "equal.circle"
        case .conflict: "exclamationmark.triangle"
        }
    }
    var color: Color {
        switch self {
        case .added: .green
        case .edited: .blue
        case .removed: .red
        case .sourceOnly, .conflict: .orange
        case .identical: .secondary
        }
    }
}
