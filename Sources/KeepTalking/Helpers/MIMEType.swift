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
}
