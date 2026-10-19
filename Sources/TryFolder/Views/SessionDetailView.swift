import SwiftUI
import AppKit
import TryFolderCore

struct SessionDetailView: View {
    @Bindable var model: AppModel
    let session: SessionRecord
    @State private var showExcluded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            if session.state == .recoveryNeeded || session.state == .interrupted {
                ContentUnavailableView {
                    Label("Session needs attention", systemImage: "exclamationmark.triangle")
                } description: { Text(session.lastMessage ?? "Retained session material requires a journal inspection before continuing.") }
                actions: { Button("Inspect Recovery") { model.recover() }.disabled(!model.canWork) }
            } else if let review = model.review {
                ReviewView(model: model, session: session, review: review)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 58)).foregroundStyle(.tint)
                    Text("Your draft is ready.").font(.largeTitle.weight(.semibold))
                    Text("Open the draft, make changes with your usual apps,\nthen return here to review the result.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("Open Draft in Finder") { model.openDraft() }.controlSize(.large)
                        Button("Review Changes") { model.reviewDraft() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canReview)
                    }
                    Text("Give other tools the draft path. They retain their own permissions; a draft is not a security sandbox.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            }
            Divider()
            footer.padding(16)
        }
        .navigationTitle(session.name)
        .sheet(isPresented: $showExcluded) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Excluded Source Items").font(.title2.bold()); Spacer(); Button("Done") { showExcluded = false }.keyboardShortcut(.defaultAction) }
                Text("These items were not copied. Kept output folders will not include them.").foregroundStyle(.secondary)
                List(model.review?.excluded ?? session.excluded) { item in
                    VStack(alignment: .leading, spacing: 4) { Text(item.path).textSelection(.enabled); Text(item.reason).font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(24).frame(width: 650, height: 440)
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(session.name).font(.title.bold()); Text(session.state.displayName).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button("Open Draft in Finder") { model.openDraft() }
                    Button("Copy Draft Path") { model.copyDraftPath() }
                    Button("Show Original in Finder") { NSWorkspace.shared.open(session.sourceURL) }
                } label: { Label("Locations", systemImage: "folder") }
                Button("Review Changes") { model.reviewDraft() }.buttonStyle(.borderedProminent).disabled(!model.canReview)
            }
            HStack(alignment: .top, spacing: 18) {
                location("Original", path: session.sourceURL.path, icon: "folder")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 18)
                location("Editable Draft", path: session.draftURL.path, icon: "folder.badge.gearshape")
            }
        }
    }
    private func location(_ name: String, path: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: icon).font(.callout.weight(.semibold))
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(path)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
    private var footer: some View {
        HStack {
            Button("Discard Draft…", role: .destructive) { model.confirmDiscard = true }.disabled(!model.canDiscard)
            if !session.excluded.isEmpty || !(model.review?.excluded.isEmpty ?? true) {
                Button("Excluded Items (\((model.review?.excluded ?? session.excluded).count))") { showExcluded = true }
            }
            Spacer()
            if let output = model.lastExport {
                Button("Show Kept Folder") { NSWorkspace.shared.open(output) }
                    .help(output.path)
            }
            if !ReleaseCapabilities.applyAndUndo {
                Text("Draft alpha · Apply / Undo unavailable").font(.caption).foregroundStyle(.secondary)
            } else if session.state == .applied {
                Button("Undo Apply") { model.undo() }.disabled(!model.canWork)
            }
            Button("Keep as New Folder…") { model.keep() }.disabled(!model.canKeep)
            if ReleaseCapabilities.applyAndUndo {
                Button("Apply Selected…") { model.confirmApply = true }.buttonStyle(.borderedProminent).disabled(!model.canApply)
            }
        }
    }
}
