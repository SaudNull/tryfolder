import Foundation
import Darwin
import ImageIO
import AppKit

/// Preview reads never follow links. Content is capped before decoding and images are downsampled.
enum BoundedPreview {
    static let textLimit = 256 * 1024
    static let documentLimit = 16 * 1024 * 1024
    enum Content: @unchecked Sendable {
        case text([String], truncated: Bool)
        case image(NSImage)
        case document(URL)
        case unavailable(String)
    }
    struct PreviewError: LocalizedError { let errorDescription: String? }
    static func descriptor(root: URL, path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw PreviewError(errorDescription: "Unsupported relative path.")
        }
        // Open every absolute ancestor without following a substituted link.
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw PreviewError(errorDescription: "Cannot open preview location.") }
        do {
            for part in root.standardizedFileURL.path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PreviewError(errorDescription: "Preview location is unavailable or contains a link.") }
                close(fd); fd = next
            }
            for (index, part) in components.enumerated() {
                let last = index == components.count - 1
                let next = openat(fd, String(part), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (last ? 0 : O_DIRECTORY))
                guard next >= 0 else { throw PreviewError(errorDescription: "File is absent, unavailable, or linked.") }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw PreviewError(errorDescription: "Only ordinary regular files can be previewed.") }
            return fd
        } catch { close(fd); throw error }
    }
    static func checkedURL(root: URL, path: String, maximumBytes: Int?) throws -> URL {
        let fd = try descriptor(root: root, path: path); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, maximumBytes == nil || info.st_size <= maximumBytes! else { throw PreviewError(errorDescription: "File exceeds the 16 MB Quick Look preview limit. Open the draft in your application.") }
        return root.appendingPathComponent(path)
    }
    static func load(root: URL, path: String) -> Content {
        do {
            let fd = try descriptor(root: root, path: path); defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return .unavailable("File information is unavailable.") }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let images: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"]
            let texts: Set<String> = ["txt", "md", "csv", "tsv", "json", "xml", "html", "css", "js", "jsx", "ts", "tsx", "swift", "py", "java", "c", "h", "cpp", "sh", "yaml", "yml", "toml", "ini", "log", "rtf"]
            let text = texts.contains(ext) || ext.isEmpty
            let limit = text ? textLimit : documentLimit
            guard text || info.st_size <= limit else { return .unavailable("Preview limited to 16 MB. File changed; use your application to inspect it.") }
            var data = Data(count: min(Int(info.st_size), limit))
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { return .unavailable("Cannot read file.") }
            data.count = count
            if images.contains(ext) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return .unavailable("Image preview is unavailable.") }
                return .image(NSImage(cgImage: image, size: .zero))
            }
            if text, !data.contains(0), let string = String(data: data, encoding: .utf8) {
                let lines = string.components(separatedBy: .newlines)
                return .text(Array(lines.prefix(3000)), truncated: info.st_size > limit || lines.count > 3000)
            }
            return .document(try checkedURL(root: root, path: path, maximumBytes: documentLimit))
        } catch { return .unavailable(error.localizedDescription) }
    }
}
