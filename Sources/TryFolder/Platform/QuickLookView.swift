import SwiftUI
import Quartz

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        view.show(url)
        return view
    }

    func updateNSView(_ nsView: QuickLookHostView, context: Context) {
        nsView.show(url)
    }

    static func dismantleNSView(_ nsView: QuickLookHostView, coordinator: ()) {
        nsView.closePreview()
    }
}

/// Keep SwiftUI's platform-view activation/deactivation on an ordinary NSView.
/// QLPreviewView also implements `deactivate`, and cannot receive it after close().
final class QuickLookHostView: NSView {
    private var previewView: QLPreviewView?
    private var previewURL: URL?

    init() {
        super.init(frame: .zero)
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autostarts = false
        // This host owns teardown, including removal before its window closes.
        preview.shouldCloseWithWindow = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        previewView = preview
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ url: URL) {
        guard let previewView, previewURL != url else { return }
        previewURL = url
        previewView.previewItem = url as NSURL
    }

    func closePreview() {
        guard let preview = previewView else { return }
        // Release ownership before calling into Quick Look, so reentry is safe.
        previewView = nil
        previewURL = nil
        preview.removeFromSuperview()
        // close() releases the item; clearing previewItem separately is unnecessary.
        preview.close()
    }
}
