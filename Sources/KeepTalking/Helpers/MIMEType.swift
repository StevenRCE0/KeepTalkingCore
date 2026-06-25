import Foundation

/// Cross-platform filename-extension → MIME type lookup.
///
/// Replaces `UniformTypeIdentifiers.UTType(filenameExtension:).preferredMIMEType`,
/// which is Apple-only. Covers the common attachment/file types; unknown
/// extensions return `nil` (callers fall back to `application/octet-stream`).
enum MIMEType {
    static func preferredMIMEType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
            // Images
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "heic": return "image/heic"
            case "heif": return "image/heif"
            case "bmp": return "image/bmp"
            case "tiff", "tif": return "image/tiff"
            case "svg": return "image/svg+xml"
            case "ico": return "image/x-icon"
            // Documents
            case "pdf": return "application/pdf"
            case "txt", "text": return "text/plain"
            case "md", "markdown": return "text/markdown"
            case "html", "htm": return "text/html"
            case "css": return "text/css"
            case "csv": return "text/csv"
            case "json": return "application/json"
            case "xml": return "application/xml"
            case "yaml", "yml": return "application/yaml"
            case "rtf": return "application/rtf"
            case "doc": return "application/msword"
            case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case "xls": return "application/vnd.ms-excel"
            case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            case "ppt": return "application/vnd.ms-powerpoint"
            case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            // Audio
            case "mp3": return "audio/mpeg"
            case "wav": return "audio/wav"
            case "m4a", "aac": return "audio/mp4"
            case "ogg", "oga": return "audio/ogg"
            case "flac": return "audio/flac"
            case "opus": return "audio/opus"
            // Video
            case "mp4", "m4v": return "video/mp4"
            case "mov": return "video/quicktime"
            case "webm": return "video/webm"
            case "avi": return "video/x-msvideo"
            case "mkv": return "video/x-matroska"
            // Archives / misc
            case "zip": return "application/zip"
            case "gz", "gzip": return "application/gzip"
            case "tar": return "application/x-tar"
            case "7z": return "application/x-7z-compressed"
            case "js", "mjs": return "text/javascript"
            case "wasm": return "application/wasm"
            default: return nil
        }
    }

    static func inferredMIMEType(
        forFileAt url: URL,
        filename: String? = nil,
        explicit: String? = nil
    ) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines),
            !explicit.isEmpty
        {
            return explicit
        }
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let mime = sniffMIMEType(data, allowTextFallback: false)
        {
            return mime
        }
        if let filename,
            let mime = preferredMIMEType(
                forExtension: URL(fileURLWithPath: filename).pathExtension)
        {
            return mime
        }
        if let mime = preferredMIMEType(forExtension: url.pathExtension) {
            return mime
        }
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let mime = sniffMIMEType(data, allowTextFallback: true)
        {
            return mime
        }
        return "application/octet-stream"
    }

    private static func sniffMIMEType(_ data: Data, allowTextFallback: Bool) -> String? {
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }
        if data.starts(with: [0x1F, 0x8B]) { return "application/gzip" }
        guard allowTextFallback else { return nil }
        let prefix = data.prefix(4096)
        if let text = String(data: prefix, encoding: .utf8) {
            let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
            if first == "{" || first == "[" { return "application/json" }
            return "text/plain"
        }
        return nil
    }
}
