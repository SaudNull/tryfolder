import SwiftUI
import AppKit
import TryFolderCore
import Darwin

struct ActivityItem: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

@MainActor @Observable
final class AppModel {
    var sessions: [SessionRecord] = []
    var selectedID: UUID? { didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedSession") } }
    var sourceCandidate: URL?
    var review: ReviewRecord?
    var selectedPaths = Set<String>()
    var selectedFile: String?
    var filter: ChangeKind?
    var search = ""
    var busy: String?
    var storageWaitHint = false
    var errorMessage: String?
    var activities: [ActivityItem] = []
    var showActivity = false
    var confirmDiscard = false
    var confirmApply = false
    var lastExport: URL?
    var originalObservationStale = false
    var engine: SessionEngine?
    let storeURL: URL
    var selected: SessionRecord? { sessions.first { $0.id == selectedID } }
    var activeSessions: [SessionRecord] { sessions.filter { $0.state != .discarded } }
    var changes: [FileChange] {
        (review?.changes ?? []).filter { ($0.kind != .identical || filter == .identical) && (filter == nil || $0.kind == filter) && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) }
    }
    var currentChange: FileChange? { review?.changes.first { $0.path == selectedFile } }
    var observedCount: Int { review?.changes.filter { $0.kind != .identical }.count ?? 0 }
    var canWork: Bool { busy == nil && engine != nil }
    var canReview: Bool { canWork && selected.map { [.editing, .reviewing, .readyToApply, .conflict].contains($0.state) } == true }
    var canApply: Bool { ReleaseCapabilities.applyAndUndo && canWork && selected.map { [.readyToApply, .conflict].contains($0.state) } == true && review?.sourceAvailable == true && !selectedPaths.isEmpty }
    var canDiscard: Bool { canWork && selected.map { [.editing, .reviewing, .readyToApply, .conflict, .interrupted].contains($0.state) } == true }
    var canKeep: Bool { canWork && review != nil && selected.map { [.editing, .reviewing, .readyToApply, .conflict, .applied].contains($0.state) } == true }

    init() {
        let args = CommandLine.arguments
        let defaults = UserDefaults.standard
        let explicitPath = args.firstIndex(of: "--store").flatMap { index -> String? in
            guard index + 1 < args.count, args[index + 1].hasPrefix("/"), !args[index + 1].contains("\0") else { return nil }
            return args[index + 1]
        }
        let savedPath = defaults.string(forKey: "sessionStorePath").flatMap { $0.hasPrefix("/") && !$0.contains("\0") ? $0 : nil }
        storeURL = (explicitPath ?? savedPath).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TryFolder/Sessions", isDirectory: true)
        selectedID = UserDefaults.standard.string(forKey: "selectedSession").flatMap(UUID.init(uuidString:))
        if args.contains("--store") && explicitPath == nil {
            errorMessage = "The --store option requires an absolute directory path. Relaunch with a valid store."
            return
        }
        if explicitPath != nil { defaults.set(storeURL.path, forKey: "sessionStorePath") }
        let components = storeURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            let volumePath = "/Volumes/" + components[2]
            guard FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?.contains(where: { $0.standardizedFileURL.path == volumePath }) == true else {
                errorMessage = "Session storage is unavailable at \(storeURL.path). Connect the volume \(volumePath) and relaunch. Your saved storage location has been retained."
                return
            }
        }
        Task { await initialize() }
    }

    private func initialize() async {
        busy = "Opening session storage…"
        let waitHint = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.busy == "Opening session storage…" else { return }
            self.storageWaitHint = true
        }
        defer { waitHint.cancel(); storageWaitHint = false; busy = nil }
        do {
            let location = storeURL
            engine = try await Task.detached { try SessionEngine(storeURL: location) }.value
            try await reload()
            await loadSelectedReview()
        } catch { report(error, context: "Cannot open session storage at \(storeURL.path)") }
    }
    func reload() async throws {
        guard let engine else { return }
        sessions = try await engine.listSessions().sorted { $0.createdAt > $1.createdAt }
        if !activeSessions.contains(where: { $0.id == selectedID }) { selectedID = activeSessions.first?.id }
    }
    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id; review = nil; selectedFile = nil; selectedPaths = []; filter = nil
        Task { await loadSelectedReview() }
    }
    func newDraft() { sourceCandidate = nil; select(nil) }
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to try"
        panel.message = "Choose an ordinary local folder on the same volume as session storage."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { stageSource(url) }
    }
    func stageSource(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "Choose one ordinary local folder."; return
        }
        var sourceInfo = stat(), storeInfo = stat()
        if lstat(url.path, &sourceInfo) == 0, stat(storeURL.path, &storeInfo) == 0, sourceInfo.st_dev != storeInfo.st_dev {
            errorMessage = "This folder and session storage are on different volumes. This release requires the same local volume. Session storage: \(storeURL.path)"; return
        }
        newDraft(); sourceCandidate = url
    }
    func create() {
        guard let sourceCandidate, canWork, let engine else { return }
        perform("Creating separate draft…") {
            let record = try await engine.create(source: sourceCandidate)
            try await self.reload(); self.selectedID = record.id; self.sourceCandidate = nil
            self.review = nil; self.originalObservationStale = true
            self.log("Created draft for \(record.name).")
        }
    }
    func reviewDraft() {
        guard let selected, canReview, let engine else { return }
        perform("Sealing and reviewing draft…") {
            let result = try await engine.review(sessionID: selected.id)
            guard self.selectedID == selected.id else { return }
            self.install(result); self.originalObservationStale = false
            try await self.reload()
            self.log("Sealed review: \(result.changes.filter { $0.kind != .identical }.count) observed changes.")
        }
    }
    func loadSelectedReview() async {
        guard let selectedID, let engine else { return }
        do {
            let result = try await engine.loadReview(sessionID: selectedID)
            if self.selectedID == selectedID {
                if let result { install(result) } else { review = nil }
                originalObservationStale = true
            }
        } catch { report(error, context: "Cannot load saved review") }
    }
    private func install(_ result: ReviewRecord) {
        review = result; selectedPaths = Set(result.changes.filter(\.canApply).map(\.path))
        selectedFile = result.changes.first { $0.kind != .identical }?.path
    }
    func keep() {
        guard let selected, let review, canKeep, let engine else { return }
        let panel = NSSavePanel()
        panel.title = "Keep reviewed draft as a new folder"
        panel.message = "Choose a new folder name. Existing destinations cannot be replaced or merged. Excluded source items are absent."
        panel.nameFieldStringValue = selected.name + " — kept"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform("Exporting sealed review…") {
            let output = try await engine.keep(sessionID: selected.id, reviewID: review.id, destination: destination)
            self.lastExport = output; self.log("Kept reviewed draft at \(output.path).")
        }
    }
    func discard() {
        guard let selected, canDiscard, let engine else { return }
        perform("Archiving draft…") {
            _ = try await engine.discard(sessionID: selected.id)
            self.review = nil; try await self.reload(); await self.loadSelectedReview()
            self.log("Archived \(selected.name). Retained session bytes; kept outputs remain user-owned.")
        }
    }
    func apply() {
        guard canApply, let selected, let review, let engine else { return }
        let paths = selectedPaths
        perform("Applying reviewed changes…") {
            _ = try await engine.apply(sessionID: selected.id, reviewID: review.id, selectedPaths: paths)
            try await self.reload(); self.log("Apply finished. Review session status for details.")
        }
    }
    func undo() {
        guard ReleaseCapabilities.applyAndUndo, let selected, canWork, let engine else { return }
        perform("Checking and undoing apply…") {
            _ = try await engine.undo(sessionID: selected.id)
            try await self.reload(); self.review = nil; self.log("Undo finished with guarded source checks.")
        }
    }
    func recover() {
        guard let selected, canWork, let engine else { return }
        perform("Inspecting recovery journal…") {
            _ = try await engine.recover(sessionID: selected.id)
            try await self.reload(); await self.loadSelectedReview(); self.log("Recovery inspection completed.")
        }
    }
    func openDraft() {
        guard let selected else { return }
        originalObservationStale = true
        if !NSWorkspace.shared.open(selected.draftURL) { errorMessage = "Cannot open draft: \(selected.draftURL.path)" }
    }
    func copyDraftPath() {
        guard let selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.draftURL.path, forType: .string)
        log("Copied exact draft path.")
    }
    func openDraftFile() {
        guard let selected, let selectedFile else { return }
        do {
            let url = try BoundedPreview.checkedURL(root: selected.draftURL, path: selectedFile, maximumBytes: nil)
            let panel = NSOpenPanel(); panel.title = "Open draft file with application"; panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
            if let saved = UserDefaults.standard.string(forKey: "editorApplication") { panel.directoryURL = URL(fileURLWithPath: saved).deletingLastPathComponent() }
            guard panel.runModal() == .OK, let app = panel.url else { return }
            UserDefaults.standard.set(app.path, forKey: "editorApplication")
            originalObservationStale = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.report(error, context: "Cannot open draft file") } }
            }
        } catch { report(error, context: "Cannot open draft file") }
    }
    private func perform(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = title
        Task {
            do { try await action() }
            catch { report(error, context: title); try? await reload() }
            busy = nil
        }
    }
    func report(_ error: Error, context: String) { errorMessage = "\(context)\n\(error.localizedDescription)"; log(errorMessage ?? "Operation failed") }
    func log(_ message: String) { activities.insert(ActivityItem(message: message), at: 0); if activities.count > 80 { activities.removeLast() } }
}
