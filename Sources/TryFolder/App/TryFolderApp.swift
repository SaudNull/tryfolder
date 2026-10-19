import SwiftUI
import AppKit
import TryFolderCore

@main
struct TryFolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("TryFolder", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1220, height: 800)
        .commands { TryFolderCommands(model: model) }
        MenuBarExtra("TryFolder", systemImage: model.busy == nil ? "folder.badge.gearshape" : "folder.badge.questionmark") {
            SessionMenu(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TryFolderCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Draft…") { model.newDraft(); model.chooseSource() }.keyboardShortcut("n")
                .disabled(!model.canWork)
        }
        CommandMenu("Draft") {
            Button("Open Draft in Finder") { model.openDraft() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.selected == nil)
            Button("Open Draft File With…") { model.openDraftFile() }.keyboardShortcut("o", modifiers: [.command, .option]).disabled(model.selectedFile == nil)
            Button("Copy Draft Path") { model.copyDraftPath() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.selected == nil)
            Divider()
            Button("Review Changes") { model.reviewDraft() }.keyboardShortcut("r").disabled(!model.canReview)
            Button("Keep as New Folder…") { model.keep() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canKeep)
            Button("Discard Draft…") { model.confirmDiscard = true }.keyboardShortcut(.delete, modifiers: [.command]).disabled(!model.canDiscard)
            if ReleaseCapabilities.applyAndUndo {
                Divider()
                Button("Apply Reviewed Changes…") { model.confirmApply = true }.disabled(!model.canApply)
                Button("Undo Last Apply") { model.undo() }.disabled(model.selected?.state != .applied || !model.canWork)
            }
        }
    }
}

struct SessionMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let session = model.selected {
            Text(String(session.name.prefix(27))).font(.headline)
            Text(model.review == nil ? "Draft active · not reviewed" : "\(model.observedCount) changes · last review")
            Button("Open Draft") { model.openDraft() }
            Button("Review Changes") { showMain(); model.reviewDraft() }.disabled(!model.canReview)
            Button("Copy Draft Path") { model.copyDraftPath() }
        } else { Text("No active draft") }
        if let busy = model.busy { Text(String(busy.prefix(30))) }
        Divider()
        Button("Show TryFolder") { showMain() }
        Button("New Draft…") { showMain(); model.chooseSource() }.disabled(!model.canWork)
        Divider()
        Button("Quit TryFolder") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
    private func showMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
