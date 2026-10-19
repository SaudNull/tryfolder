import SwiftUI

struct StartView: View {
    @Bindable var model: AppModel
    @State private var targeted = false
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("A LITTLE ROOM TO EXPERIMENT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Text("Try it.\nKeep what works.")
                    .font(.system(size: 48, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
                Text("Create a separate draft. Edit it with your apps.\nReview before applying.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(spacing: 18) {
                    Image(systemName: "folder.fill").font(.system(size: 68)).foregroundStyle(.tint).symbolRenderingMode(.hierarchical)
                    if let folder = model.sourceCandidate {
                        Text(folder.lastPathComponent).font(.title3.weight(.medium))
                        Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Button("Create Draft") { model.create() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canWork)
                        Button("Choose Another Folder…") { model.chooseSource() }.buttonStyle(.link).disabled(!model.canWork)
                    } else {
                        Text("Drop a folder here").font(.headline)
                        Button("Choose Folder…") { model.chooseSource() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canWork)
                    }
                }
                .padding(30).frame(maxWidth: 420, minHeight: 250)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: model.sourceCandidate == nil ? [6, 5] : [])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard urls.count == 1, model.canWork else { return false }
                    model.stageSource(urls[0]); return true
                } isTargeted: { targeted = $0 }
                Label("Original content stays in place while you edit the draft.", systemImage: "square.on.square").font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 7) {
                    Text("Ordinary local folders · same volume as session storage").font(.caption)
                    Text(model.storeURL.path).font(.caption2.monospaced()).textSelection(.enabled)
                    Text("Unsupported items are reported. No account or cloud service required.").font(.caption2)
                }.foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.vertical, 52).padding(.horizontal, 36).frame(maxWidth: .infinity)
        }
        .navigationTitle("New Draft")
    }
}
