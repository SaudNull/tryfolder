import SwiftUI
import TryFolderCore

struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 290)
        } detail: {
            VStack(spacing: 0) {
                if let busy = model.busy {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(busy); Spacer() }
                        .font(.callout).padding(12).background(.regularMaterial)
                    Divider()
                }
                if model.storageWaitHint {
                    Label("Storage is taking longer to open. macOS may be waiting for folder or removable-volume access. Check for its permission dialog and confirm the storage volume is connected.", systemImage: "externaldrive.badge.questionmark")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                    Divider()
                }
                if let session = model.selected { SessionDetailView(model: model, session: session) }
                else { StartView(model: model) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { model.showActivity.toggle() } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .help("Show activity for this launch")
            }
        }
        .sheet(isPresented: $model.showActivity) { ActivityView(model: model) }
        .alert("TryFolder", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Discard this draft?", isPresented: $model.confirmDiscard, titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive) { model.discard() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The session will be archived with its bytes retained. Original files and any kept output folders remain in place.") }
        .confirmationDialog("Apply this sealed review?", isPresented: $model.confirmApply, titleVisibility: .visible) {
            Button("Apply \(model.selectedPaths.count) Reviewed Changes") { model.apply() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Save and close relevant editing sessions first. Only selected changes from this sealed review will be applied, file by file. Newer live draft edits are excluded.") }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("TryFolder", systemImage: "folder.badge.gearshape").font(.headline)
                Spacer()
                Button { model.newDraft() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New draft")
            }.padding(18)
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                Section("Drafts") {
                    ForEach(model.activeSessions) { session in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.name).lineLimit(1)
                                Text(session.state.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: session.state == .conflict ? "exclamationmark.triangle" : "folder") }
                        .tag(session.id)
                    }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Text("VERSION \(ReleaseCapabilities.version)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("Try changes. Keep what works.").font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
    }
}

struct ActivityView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Activity").font(.title2.bold()); Spacer(); Button("Done") { model.showActivity = false }.keyboardShortcut(.defaultAction) }
            Text("Session status is saved on disk. This activity list covers the current launch.").foregroundStyle(.secondary)
            if model.activities.isEmpty { ContentUnavailableView("No activity yet", systemImage: "clock") }
            else {
                List(model.activities) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.message).textSelection(.enabled)
                        Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
            Text("Session storage").font(.caption.bold())
            Text(model.storeURL.path).font(.caption.monospaced()).textSelection(.enabled)
        }.padding(24).frame(width: 680, height: 470)
    }
}

extension SessionState {
    var displayName: String {
        switch self {
        case .preparing: "Preparing"
        case .editing: "Draft active"
        case .reviewing: "Reviewing"
        case .readyToApply: "Review ready"
        case .applying: "Applying"
        case .applied: "Applied"
        case .conflict: "Needs review"
        case .interrupted: "Interrupted"
        case .discarded: "Archived"
        case .recoveryNeeded: "Recovery needed"
        }
    }
}
