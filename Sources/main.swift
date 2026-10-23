// Elconvo — a drag-and-drop file converter for macOS.
// Uses only what ships with macOS (ImageIO, Core Image, PDFKit, AVFoundation,
// afconvert, avconvert, bsdtar) and picks up optional extras when present:
// ImageMagick (WebP), ffmpeg (MP3/OGG/WebM/MKV…), Adobe DNG Converter (RAW → DNG).

import SwiftUI
import AppKit
import ImageIO
import CoreImage
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import ServiceManagement
import Vision

// MARK: - Formats

enum Kind: String, CaseIterable {
    case image = "Images", raw = "RAW Photos", audio = "Audio", video = "Video"
    case document = "Documents", pdf = "PDF", spreadsheet = "Spreadsheets", data = "Data", subtitle = "Subtitles", model3d = "3D Models"
    case archive = "Archives", folder = "Folders"
    case unknown = "Other"

    static func of(_ url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           !(inputExtensions[.document]!.contains(ext)) { return .folder }
        for (kind, exts) in inputExtensions where exts.contains(ext) { return kind }
        return .unknown
    }

    static let inputExtensions: [Kind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif",
                 "psd", "ico", "icns", "jp2", "tga", "exr", "svg", "jxl", "dds"],
        .raw: ["arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "dng", "raf", "orf", "rw2",
               "pef", "srw", "x3f", "3fr", "fff", "iiq", "mos", "mrw", "erf", "kdc", "raw", "rwl"],
        .audio: ["mp3", "wav", "aif", "aiff", "aifc", "m4a", "aac", "flac", "caf", "m4b", "m4r",
                 "ogg", "oga", "opus", "wma", "ac3", "amr", "3gp"],
        .video: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3g2"],
        .document: ["txt", "text", "md", "markdown", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt",
                    "wordml", "webarchive"],
        .pdf: ["pdf", "ai"],   // Illustrator files are PDF-compatible
        .spreadsheet: ["xlsx", "xlsm", "ods", "xls", "numbers"],
        .data: ["json", "plist", "csv", "tsv"],
        .subtitle: ["srt", "vtt"],
        .model3d: Kind.modelExtensions,
        .archive: ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "txz", "iso", "cpio",
                   "xar", "cab", "lha", "lzh", "aar", "jar", "apk", "ipa", "epub"],
    ]
}

extension NSPasteboard {
    var fileURLs: [URL] { readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] }
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

struct Format: Hashable, Identifiable {
    let id: String      // unique key, e.g. "m4a-alac"
    let ext: String     // output file extension
    let label: String
    var needs: Tool? = nil

    /// The label for menus, saying what's missing when the format can't be produced yet.
    var menuLabel: String { label + (Tools.has(needs) ? "" : " — needs \(needs!.rawValue)") }
}

enum Tool: String { case magick = "ImageMagick", ffmpeg = "ffmpeg", dng = "Adobe DNG Converter" }

enum Tools {
    static func find(_ names: [String]) -> String? {
        names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static let magick = find(["/opt/homebrew/bin/magick", "/usr/local/bin/magick"])
    static let ffmpeg = find(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
    static let dng = find(["/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"])

    /// Names of the encoders this ffmpeg build has (read once).
    static let ffmpegEncoders: Set<String> = {
        guard let ffmpeg else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Set(text.split(separator: "\n").compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) })
    }()

    static func has(_ tool: Tool?) -> Bool {
        switch tool {
        case nil: return true
        case .magick: return magick != nil
        case .ffmpeg: return ffmpeg != nil
        case .dng: return dng != nil
        }
    }
}

enum Formats {
    static let imageOut: [Format] = [
        .init(id: "jpg", ext: "jpg", label: "JPEG"),
        .init(id: "png", ext: "png", label: "PNG"),
        .init(id: "heic", ext: "heic", label: "HEIC"),
        .init(id: "avif", ext: "avif", label: "AVIF"),
        .init(id: "webp", ext: "webp", label: "WebP", needs: .magick),
        .init(id: "tiff", ext: "tiff", label: "TIFF"),
        .init(id: "gif", ext: "gif", label: "GIF"),
        .init(id: "bmp", ext: "bmp", label: "BMP"),
        .init(id: "jp2", ext: "jp2", label: "JPEG 2000"),
        .init(id: "psd", ext: "psd", label: "Photoshop"),
        .init(id: "tga", ext: "tga", label: "TGA"),
        .init(id: "exr", ext: "exr", label: "OpenEXR (HDR)"),
        .init(id: "hdr", ext: "hdr", label: "Radiance HDR", needs: .magick),
        .init(id: "eps", ext: "eps", label: "EPS", needs: .magick),
        .init(id: "wbmp", ext: "wbmp", label: "WBMP", needs: .magick),
        .init(id: "svg", ext: "svg", label: "SVG (embedded image)"),
        .init(id: "ico", ext: "ico", label: "Icon (ICO)"),
        .init(id: "icns", ext: "icns", label: "Icon (ICNS)"),
        .init(id: "img-pdf", ext: "pdf", label: "PDF"),
    ]
    static let rawOut: [Format] = [
        .init(id: "dng", ext: "dng", label: "DNG (RAW)", needs: .dng),
        .init(id: "tiff16", ext: "tiff", label: "TIFF 16-bit"),
        .init(id: "png16", ext: "png", label: "PNG 16-bit"),
    ] + imageOut.filter { ["jpg", "heic", "avif", "webp", "psd"].contains($0.id) }
    static let audioOut: [Format] = [
        .init(id: "m4a-aac", ext: "m4a", label: "M4A (AAC)"),
        .init(id: "m4a-alac", ext: "m4a", label: "M4A (Apple Lossless)"),
        .init(id: "mp3", ext: "mp3", label: "MP3", needs: .ffmpeg),
        .init(id: "wav", ext: "wav", label: "WAV"),
        .init(id: "aiff", ext: "aiff", label: "AIFF"),
        .init(id: "flac", ext: "flac", label: "FLAC"),
        .init(id: "caf", ext: "caf", label: "CAF"),
        .init(id: "aac", ext: "aac", label: "AAC (raw ADTS)"),
        .init(id: "m4r", ext: "m4r", label: "iPhone Ringtone (M4R)"),
        .init(id: "ogg", ext: "ogg", label: "OGG Vorbis", needs: .ffmpeg),
        .init(id: "wma", ext: "wma", label: "WMA", needs: .ffmpeg),
        .init(id: "mmf", ext: "mmf", label: "MMF (mobile)", needs: .ffmpeg),
        .init(id: "opus", ext: "opus", label: "Opus", needs: .ffmpeg),
    ]
    static let videoOut: [Format] = [
        .init(id: "mp4", ext: "mp4", label: "MP4 (H.264)"),
        .init(id: "mov-hevc", ext: "mov", label: "MOV (HEVC)"),
        .init(id: "mov", ext: "mov", label: "MOV (H.264)"),
        .init(id: "m4v", ext: "m4v", label: "M4V"),
        .init(id: "vid-gif", ext: "gif", label: "Animated GIF"),
        .init(id: "webm", ext: "webm", label: "WebM", needs: .ffmpeg),
        .init(id: "mkv", ext: "mkv", label: "MKV", needs: .ffmpeg),
        .init(id: "avi", ext: "avi", label: "AVI", needs: .ffmpeg),
        .init(id: "wmv", ext: "wmv", label: "WMV", needs: .ffmpeg),
        .init(id: "flv", ext: "flv", label: "FLV", needs: .ffmpeg),
        .init(id: "mpg", ext: "mpg", label: "MPEG-2 (MPG)", needs: .ffmpeg),
        .init(id: "3gp", ext: "3gp", label: "3GP (mobile)", needs: .ffmpeg),
        .init(id: "3g2", ext: "3g2", label: "3G2 (mobile)", needs: .ffmpeg),
    ] + audioOut.map { Format(id: "audio-" + $0.id, ext: $0.ext, label: "Audio only: " + $0.label, needs: $0.needs) }
    static let documentOut: [Format] = [
        .init(id: "doc-pdf", ext: "pdf", label: "PDF"),
        .init(id: "docx", ext: "docx", label: "Word (DOCX)"),
        .init(id: "doc", ext: "doc", label: "Word 97 (DOC)"),
        .init(id: "odt", ext: "odt", label: "OpenDocument (ODT)"),
        .init(id: "rtf", ext: "rtf", label: "Rich Text (RTF)"),
        .init(id: "html", ext: "html", label: "HTML"),
        .init(id: "txt", ext: "txt", label: "Plain Text"),
        .init(id: "webarchive", ext: "webarchive", label: "Web Archive"),
    ]
    static let pdfOut: [Format] = [
        .init(id: "pdf-png", ext: "png", label: "PNG (each page)"),
        .init(id: "pdf-jpg", ext: "jpg", label: "JPEG (each page)"),
        .init(id: "pdf-tiff", ext: "tiff", label: "TIFF (each page)"),
        .init(id: "pdf-txt", ext: "txt", label: "Plain Text"),
        .init(id: "pdf-rtf", ext: "rtf", label: "Rich Text (RTF)"),
        .init(id: "pdf-docx", ext: "docx", label: "Word (DOCX)"),
    ]
    static let subtitleOut: [Format] = [
        .init(id: "srt", ext: "srt", label: "SubRip (SRT)"),
        .init(id: "vtt", ext: "vtt", label: "WebVTT"),
        .init(id: "sub-txt", ext: "txt", label: "Plain Text"),
    ]
    static let archiveOut: [Format] = [
        .init(id: "zip", ext: "zip", label: "ZIP"),
        .init(id: "7z", ext: "7z", label: "7-Zip"),
        .init(id: "tgz", ext: "tar.gz", label: "TAR.GZ"),
        .init(id: "txz", ext: "tar.xz", label: "TAR.XZ"),
        .init(id: "tbz", ext: "tar.bz2", label: "TAR.BZ2"),
        .init(id: "tar", ext: "tar", label: "TAR"),
    ]
    static let archiveIDs = Set(archiveOut.map(\.id))
    static let extract = Format(id: "extract", ext: "", label: "Extract (Unarchive)")

    static let dataOut: [Format] = [
        .init(id: "json", ext: "json", label: "JSON"),
        .init(id: "plist", ext: "plist", label: "Property List (XML)"),
        .init(id: "bplist", ext: "plist", label: "Property List (binary)"),
        .init(id: "csv", ext: "csv", label: "CSV"),
        .init(id: "tsv", ext: "tsv", label: "TSV"),
        .init(id: "xlsx", ext: "xlsx", label: "Excel (XLSX)"),
    ]

    /// Everything a kind can become: real conversions first, then archive options.
    static func outputs(for kind: Kind) -> [Format] { conversions(for: kind) + archiving(for: kind) }

    static func archiving(for kind: Kind) -> [Format] {
        let verb = kind == .archive ? "Repack as " : "Compress to "
        return archiveOut.map { Format(id: $0.id, ext: $0.ext, label: verb + $0.label) }
    }

    static func conversions(for kind: Kind) -> [Format] {
        switch kind {
        case .image: return imageOut
        case .raw: return rawOut
        case .audio: return audioOut
        case .video: return videoOut
        case .document: return documentOut
        case .pdf: return pdfOut
        case .spreadsheet: return Spreadsheet.outputs
        case .data: return dataOut
        case .subtitle: return subtitleOut
        case .model3d: return Models3D.outputs
        case .archive: return [extract]
        case .folder, .unknown: return []
        }
    }

    /// The handful of big targets the shift-drag shelf offers for a kind.
    static func shelf(for kind: Kind) -> [Format] {
        let ids: [String] = switch kind {
        case .image: ["jpg", "png", "heic", "webp", "avif", "img-pdf"]
        case .raw: ["dng", "tiff16", "jpg", "heic"]
        case .audio: ["m4a-aac", "mp3", "wav", "flac", "aiff"]
        case .video: ["mp4", "mov", "mov-hevc", "m4v", "webm", "mkv", "vid-gif", "audio-m4a-aac", "audio-mp3"]
        case .document: ["doc-pdf", "docx", "txt", "html", "rtf"]
        case .pdf: ["pdf-png", "pdf-jpg", "pdf-txt", "pdf-docx"]
        case .spreadsheet: ["sheet-csv", "xlsx", "sheet-pdf", "sheet-json", "sheet-tsv", "sheet-html"]
        case .data: ["json", "csv", "plist", "xlsx"]
        case .subtitle: ["srt", "vtt", "sub-txt"]
        case .model3d: ["stl", "3mf", "obj", "usdz", "ply"]
        case .archive: ["extract"]
        case .folder, .unknown: []
        }
        let all = conversions(for: kind)
        return ids.compactMap { id in all.first { $0.id == id } }.filter { Tools.has($0.needs) }
    }

    static func defaultOutput(for kind: Kind, ext: String) -> Format? {
        let preferred: [String] = switch kind {
        case .image: ext == "png" ? ["jpg"] : ["png"]
        case .raw: Tools.dng != nil && ext != "dng" ? ["dng"] : ["jpg"]
        case .audio: ext == "m4a" ? ["wav"] : ["m4a-aac"]
        case .video: ext == "mp4" ? ["mov-hevc"] : ["mp4"]
        case .document: ext == "pdf" ? ["docx"] : ["doc-pdf"]
        case .pdf: ["pdf-png"]
        case .spreadsheet: ["sheet-csv"]
        case .data: ext == "json" ? ["csv"] : ["json"]
        case .subtitle: ext == "srt" ? ["vtt"] : ["srt"]
        case .model3d: ext == "stl" ? ["3mf"] : ["stl"]
        case .archive: ["extract"]
        case .folder: ["zip"]
        case .unknown: []
        }
        return outputs(for: kind).first { preferred.contains($0.id) }
    }

    /// Compact name for a wheel petal.
    static func short(_ f: Format) -> String { shortNames[f.id] ?? f.ext.uppercased() }

    private static let shortNames = ["img-pdf": "PDF", "tiff16": "TIFF 16", "png16": "PNG 16", "m4a-aac": "M4A", "m4a-alac": "ALAC",
                     "mov-hevc": "MOV HEVC", "vid-gif": "GIF", "audio-m4a-aac": "M4A Audio", "audio-mp3": "MP3 Audio",
                     "doc-pdf": "PDF", "pdf-png": "PNG", "pdf-jpg": "JPG", "pdf-tiff": "TIFF", "pdf-txt": "TXT",
                     "pdf-rtf": "RTF", "pdf-docx": "DOCX", "extract": "Extract", "tgz": "TAR.GZ", "txz": "TAR.XZ", "tbz": "TAR.BZ2", "m4r": "Ringtone",
                     "sub-txt": "TXT", "bplist": "PLIST",
                     "sheet-csv": "CSV", "sheet-tsv": "TSV", "sheet-json": "JSON", "sheet-html": "HTML", "sheet-pdf": "PDF"]

    static func byID(_ id: String) -> Format? {
        Kind.allCases.lazy.flatMap { conversions(for: $0) }.first { $0.id == id }
            ?? archiveOut.first { $0.id == id }
    }
}

// MARK: - Options

enum Quality: String, CaseIterable, Identifiable {
    case small = "Small", balanced = "Balanced", high = "High", maximum = "Maximum"
    var id: String { rawValue }
    var lossy: Double { [.small: 0.55, .balanced: 0.75, .high: 0.88, .maximum: 1.0][self]! }
    var audioBitrate: Int { [.small: 96_000, .balanced: 160_000, .high: 256_000, .maximum: 320_000][self]! }
    var ffmpegCRF: String { [.small: "32", .balanced: "26", .high: "21", .maximum: "17"][self]! }
}

struct Options {
    var quality: Quality = .high
    var maxImageSize: Int = 0          // 0 = original
    var videoHeight: Int = 0           // 0 = original
    var gifFPS: Int = 12
    var gifWidth: Int = 480
    var outputFolder: URL? = nil       // nil = next to the original
    var stripMetadata = false
}

// MARK: - Conversion engine

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Converter {
    /// Long jobs report steps ("Page 3 of 8") here; the progress window sets it for the task it runs.
    @TaskLocal static var report: (@Sendable (String) -> Void)?

    /// Core Image contexts are costly to make (GPU setup), so every render shares these.
    static let ciContext = CIContext()
    static let rawContext = CIContext(options: [.workingFormat: CIFormat.RGBAh])

    /// Characters PDF text can carry that are illegal in DOCX/ODT XML.
    static let controlCharacters = "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]"

    /// Writes text parts (path → contents) into a zip: the container DOCX and 3MF both use.
    static func writeZip(_ parts: [String: String], to out: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("elconvo-zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        for (path, text) in parts {
            let file = stage.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let top = Set(parts.keys.map { String($0.split(separator: "/")[0]) }).sorted()
        try? fm.removeItem(at: out)
        try runSync("/usr/bin/tar", ["-c", "-f", out.path, "--format", "zip", "-C", stage.path] + top, env: ["COPYFILE_DISABLE": "1"])
    }

    /// A temporary file, deleted when `body` returns.
    static func withTempFile<T>(ext: String, _ body: (URL) throws -> T) rethrows -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    /// A PDF page as a bitmap, `scale` pixels per point, upright.
    static func render(_ page: PDFPage, scale: CGFloat, box: PDFDisplayBox = .mediaBox) -> CGImage? {
        var size = page.bounds(for: box).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let picture = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: box)
        var rect = CGRect(origin: .zero, size: picture.size)
        return picture.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Converts one file and returns the written file (or folder, for multi-page output).
    static func convert(_ input: URL, to format: Format, options: Options) async throws -> URL {
        guard Tools.has(format.needs) else {
            throw ConvertError("\(format.label) needs \(format.needs!.rawValue), which isn't installed.")
        }
        let kind = Kind.of(input)
        if format.id == "extract" { return try await extract(input, into: options.outputFolder) }
        if Formats.archiveIDs.contains(format.id) {
            if kind == .archive { return try await repack(input, as: format, options: options) }
            return try await compress([input], as: format, options: options)
        }
        let folder = options.outputFolder ?? input.deletingLastPathComponent()
        let out = uniqueURL(in: folder, base: input.deletingPathExtension().lastPathComponent, ext: format.ext, avoiding: input)

        switch kind {
        case .image, .raw:
            if format.id == "dng" { return try await rawToDNG(input, out: out) }
            try image(input, to: out, format: format, options: options, raw: kind == .raw)
        case .audio:
            try await audio(input, to: out, formatID: format.id, options: options)
        case .video:
            if format.id.hasPrefix("audio-") {
                try await videoToAudio(input, to: out, formatID: String(format.id.dropFirst(6)), options: options)
            } else if format.id == "vid-gif" {
                try await videoToGIF(input, to: out, options: options)
            } else {
                try await video(input, to: out, formatID: format.id, options: options)
            }
        case .document:
            try await MainActor.run { try document(input, to: out, formatID: format.id) }
        case .pdf:
            if ["pdf-png", "pdf-jpg", "pdf-tiff"].contains(format.id) {
                return try pdfToImages(input, out: out, format: format, options: options)
            }
            if format.id == "pdf-docx", #available(macOS 26.0, *) {
                try await PDFToWord.convert(input, to: out)   // keeps headings, lists and tables
            } else {
                try await MainActor.run { try pdfToText(input, to: out, formatID: format.id) }
            }
        case .spreadsheet:
            return try await Spreadsheet.convert(input, to: out, formatID: format.id)
        case .data:
            try data(input, to: out, formatID: format.id)
        case .subtitle:
            try subtitles(input, to: out, formatID: format.id)
        case .model3d:
            try Models3D.convert(input, to: out, formatID: format.id)
        case .archive, .folder, .unknown:
            throw ConvertError("Elconvo can only archive this item.")
        }
        guard FileManager.default.fileExists(atPath: out.path) else { throw ConvertError("No output was produced.") }
        return out
    }

    /// `folder/base.ext`, or "base converted.ext", "base converted 2.ext"… if that's taken.
    static func uniqueURL(in folder: URL, base: String, ext: String, avoiding input: URL? = nil) -> URL {
        func make(_ name: String) -> URL { folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)") }
        let fm = FileManager.default
        let first = make(base)
        if first.standardizedFileURL != input?.standardizedFileURL && !fm.fileExists(atPath: first.path) { return first }
        for n in 1... {
            let candidate = make(n == 1 ? "\(base) converted" : "\(base) converted \(n)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError()
    }

    // MARK: Images

    static let utiFor: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "avif": "public.avif",
        "tiff": "public.tiff", "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp", "jp2": "public.jpeg-2000",
        "psd": "com.adobe.photoshop-image", "tga": "com.truevision.tga-image", "ico": "com.microsoft.ico",
        "icns": "com.apple.icns", "tiff16": "public.tiff", "png16": "public.png", "exr": "com.ilm.openexr-image",
    ]

    static func loadImage(_ url: URL, raw: Bool, sixteenBit: Bool) throws -> (CGImage, [CFString: Any]) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]

        if raw, let filter = CIRAWFilter(imageURL: url), let ci = filter.outputImage {
            let ctx = rawContext
            let format: CIFormat = sixteenBit ? .RGBA16 : .RGBA8
            let space = CGColorSpace(name: sixteenBit ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
            if let cg = ctx.createCGImage(ci, from: ci.extent, format: format, colorSpace: space) {
                return (cg, props)
            }
        }
        if let source, let cg = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            return (cg, props)
        }
        // SVG, EPS and anything else NSImage understands.
        if let ns = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: ns.size)
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return (cg, props) }
        }
        throw ConvertError("Couldn't read this image.")
    }

    static func image(_ input: URL, to out: URL, format: Format, options: Options, raw: Bool) throws {
        if ["webp", "hdr", "eps", "wbmp", "svg"].contains(format.id) {
            // ImageIO can't write these: make a PNG first, then hand it to ImageMagick or wrap it in SVG.
            try withTempFile(ext: "png") { png in
                try image(input, to: png, format: Formats.byID("png")!, options: options, raw: raw)
                if format.id == "svg" {
                    // A real SVG file that browsers and design apps open, holding the picture (not traced vectors).
                    let data = try Data(contentsOf: png)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
                    else { throw ConvertError("Couldn't read the image.") }
                    try """
                    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
                    <image width="\(w)" height="\(h)" xlink:href="data:image/png;base64,\(data.base64EncodedString())"/>
                    </svg>
                    """.write(to: out, atomically: true, encoding: .utf8)
                } else {
                    try runSync(Tools.magick!, [png.path, "-quality", "\(Int(options.quality.lossy * 100))", out.path])
                }
            }
            return
        }

        let sixteen = format.id == "tiff16" || format.id == "png16"
        var (cg, props) = try loadImage(input, raw: raw, sixteenBit: sixteen)
        cg = applyOrientation(cg, props: props, alreadyApplied: raw)
        if format.id == "ico" { cg = resized(cg, maxSide: 256) }
        else if format.id == "icns" { cg = resized(cg, maxSide: 1024) }
        else if options.maxImageSize > 0 { cg = resized(cg, maxSide: options.maxImageSize) }
        if ["jpg", "bmp"].contains(format.id) { cg = flattened(cg) }

        if format.id == "img-pdf" {
            let doc = PDFDocument()
            let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))!
            doc.insert(page, at: 0)
            guard doc.write(to: out) else { throw ConvertError("Couldn't write the PDF.") }
            return
        }

        guard let uti = utiFor[format.id],
              let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil)
        else { throw ConvertError("This Mac can't write \(format.label).") }

        var destProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality.lossy]
        if !options.stripMetadata { destProps.merge(Ops.keptMetadata(props)) { $1 } }
        destProps[kCGImagePropertyOrientation] = 1   // pixels are already upright
        CGImageDestinationAddImage(dest, cg, destProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn't write \(format.label).") }
    }

    static func applyOrientation(_ image: CGImage, props: [CFString: Any], alreadyApplied: Bool) -> CGImage {
        // CGImageSourceCreateImageAtIndex ignores EXIF orientation, so bake it in.
        guard !alreadyApplied, let raw = props[kCGImagePropertyOrientation] as? UInt32, raw != 1,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return image }
        let ci = CIImage(cgImage: image).oriented(orientation)
        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }

    static func resized(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        let bpc = image.bitsPerComponent == 16 ? 16 : 8
        let info = bpc == 16 ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                             : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Paints transparent areas white for formats without alpha.
    static func flattened(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func rawToDNG(_ input: URL, out: URL) async throws -> URL {
        if input.pathExtension.lowercased() == "dng" { throw ConvertError("This file is already a DNG.") }
        // -c lossless compression, -p1 medium preview; the converter names the file itself.
        try await run(Tools.dng!, ["-c", "-p1", "-d", out.deletingLastPathComponent().path,
                                   "-o", out.lastPathComponent, input.path])
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ConvertError("Adobe DNG Converter didn't produce a file (is the camera supported by your version?).")
        }
        return out
    }

    // MARK: Audio

    static func afconvertArgs(_ formatID: String, options: Options) -> [String]? {
        switch formatID {
        case "m4a-aac", "m4r": return ["-f", "m4af", "-d", "aac", "-b", "\(options.quality.audioBitrate)", "-s", "1"]
        case "aac": return ["-f", "adts", "-d", "aac", "-b", "\(options.quality.audioBitrate)", "-s", "1"]
        case "m4a-alac": return ["-f", "m4af", "-d", "alac"]
        case "wav": return ["-f", "WAVE", "-d", "LEI16"]
        case "aiff": return ["-f", "AIFF", "-d", "BEI16"]
        case "flac": return ["-f", "flac", "-d", "flac"]
        case "caf": return ["-f", "caff", "-d", "LEI16"]
        default: return nil
        }
    }

    static func ffmpegAudioArgs(_ formatID: String, options: Options) -> [String] {
        let kbps = "\(options.quality.audioBitrate / 1000)k"
        switch formatID {
        case "mp3": return ["-codec:a", "libmp3lame", "-b:a", kbps]
        case "ogg":
            // Homebrew's ffmpeg may lack libvorbis; its built-in Vorbis encoder is marked experimental but works.
            return Tools.ffmpegEncoders.contains("libvorbis") ? ["-codec:a", "libvorbis", "-b:a", kbps]
                : ["-codec:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", kbps]
        case "wma": return ["-codec:a", "wmav2", "-b:a", kbps]
        case "mmf": return ["-codec:a", "adpcm_yamaha", "-ar", "8000", "-ac", "1"]
        case "opus": return ["-codec:a", "libopus", "-b:a", kbps]
        case "m4a-aac", "aac": return ["-codec:a", "aac", "-b:a", kbps]
        case "m4a-alac": return ["-codec:a", "alac"]
        case "flac": return ["-codec:a", "flac"]
        default: return []
        }
    }

    static func audio(_ input: URL, to out: URL, formatID: String, options: Options) async throws {
        if let args = afconvertArgs(formatID, options: options) {
            do { try await run("/usr/bin/afconvert", args + [input.path, out.path]); return }
            catch {
                // Core Audio can't read OGG/Opus/WMA; fall back to ffmpeg if we have it.
                try? FileManager.default.removeItem(at: out)
                guard Tools.ffmpeg != nil else { throw error }
            }
        }
        try await ffmpeg(input, out: out, ["-vn"] + ffmpegAudioArgs(formatID, options: options) + metadataArgs(options))
    }

    // MARK: Video

    static func avconvertPreset(_ formatID: String, height: Int) -> String {
        let hevc = formatID == "mov-hevc"
        switch height {
        case 2160: return hevc ? "PresetHEVC3840x2160" : "Preset3840x2160"
        case 1080: return hevc ? "PresetHEVC1920x1080" : "Preset1920x1080"
        case 720: return "Preset1280x720"
        case 480: return "Preset640x480"
        default: return hevc ? "PresetHEVCHighestQuality" : "PresetHighestQuality"
        }
    }

    static func video(_ input: URL, to out: URL, formatID: String, options: Options) async throws {
        let builtIn = ["mp4", "mov", "mov-hevc", "m4v"].contains(formatID)
        let readable = (try? await AVURLAsset(url: input).load(.isReadable)) ?? false
        if builtIn && readable {
            var args = ["--source", input.path, "--output", out.path, "--replace",
                        "--preset", avconvertPreset(formatID, height: options.videoHeight)]
            if !options.stripMetadata { args.append("--disableMetadataFilter") }
            try await run("/usr/bin/avconvert", args)
            return
        }
        guard Tools.ffmpeg != nil else {
            throw ConvertError(readable ? "\(out.pathExtension.uppercased()) output needs ffmpeg."
                                        : "macOS can't read .\(input.pathExtension) video; install ffmpeg to convert it.")
        }
        var args: [String] = []
        if options.videoHeight > 0 { args += ["-vf", "scale=-2:'min(\(options.videoHeight),ih)'"] }
        switch formatID {
        case "webm": args += ["-c:v", "libvpx-vp9", "-crf", options.quality.ffmpegCRF, "-b:v", "0", "-c:a", "libopus"]
        case "wmv": args += ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case "mpg": args += ["-c:v", "mpeg2video", "-q:v", "3", "-c:a", "mp2", "-b:a", "192k"]
        case "3gp", "3g2": args += ["-c:v", "libx264", "-profile:v", "baseline", "-crf", options.quality.ffmpegCRF,
                                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "1", "-ar", "22050", "-b:a", "64k"]
        case "mov-hevc": args += ["-c:v", "libx265", "-crf", options.quality.ffmpegCRF, "-tag:v", "hvc1", "-c:a", "aac"]
        default: args += ["-c:v", "libx264", "-crf", options.quality.ffmpegCRF, "-pix_fmt", "yuv420p", "-c:a", "aac"]
        }
        if ["mp4", "mov", "m4v", "mov-hevc"].contains(formatID) { args += ["-movflags", "+faststart"] }
        try await ffmpeg(input, out: out, args + metadataArgs(options))
    }

    static func videoToAudio(_ input: URL, to out: URL, formatID: String, options: Options) async throws {
        let readable = (try? await AVURLAsset(url: input).load(.isReadable)) ?? false
        if !readable || afconvertArgs(formatID, options: options) == nil {
            guard Tools.ffmpeg != nil else { throw ConvertError("This needs ffmpeg.") }
            try await ffmpeg(input, out: out, ["-vn"] + ffmpegAudioArgs(formatID, options: options))
            return
        }
        // Pull the soundtrack out with AVFoundation, then re-encode with Core Audio.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await run("/usr/bin/avconvert", ["--source", input.path, "--output", tmp.path, "--preset", "PresetAppleM4A"])
        try await audio(tmp, to: out, formatID: formatID, options: options)
    }

    static func videoToGIF(_ input: URL, to out: URL, options: Options) async throws {
        let asset = AVURLAsset(url: input)
        guard (try? await asset.load(.isReadable)) == true else {
            guard Tools.ffmpeg != nil else { throw ConvertError("macOS can't read this video; install ffmpeg.") }
            try await ffmpeg(input, out: out, ["-vf", "fps=\(options.gifFPS),scale=\(options.gifWidth):-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"])
            return
        }
        let duration = try await asset.load(.duration).seconds
        let frames = max(1, min(Int(duration * Double(options.gifFPS)), 1500))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.gifWidth, height: options.gifWidth * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil)
        else { throw ConvertError("Couldn't create the GIF.") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1.0 / Double(options.gifFPS)
        for i in 0..<frames {
            let time = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            let (frame, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn't write the GIF.") }
    }

    static func metadataArgs(_ options: Options) -> [String] {
        options.stripMetadata ? ["-map_metadata", "-1"] : []
    }

    static func ffmpeg(_ input: URL, out: URL, _ args: [String]) async throws {
        try await run(Tools.ffmpeg!, ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path] + args + [out.path])
    }

    // MARK: Documents

    static let docTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument,
        "html": .html, "txt": .plain, "webarchive": .webArchive, "pdf-rtf": .rtf, "pdf-docx": .officeOpenXML,
    ]

    @MainActor static func readDocument(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try AttributedString(markdown: text, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))
            let result = NSMutableAttributedString(parsed)
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: result.length))
            // Re-apply bold/italic that the inline presentation intents describe.
            parsed.runs.forEach { run in
                guard let intent = run.inlinePresentationIntent else { return }
                let range = NSRange(run.range, in: parsed)
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
                } else if !traits.isEmpty {
                    let d = NSFont.systemFont(ofSize: 13).fontDescriptor.withSymbolicTraits(traits)
                    result.addAttribute(.font, value: NSFont(descriptor: d, size: 13)!, range: range)
                }
            }
            return result
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    @MainActor static func writeDocument(_ text: NSAttributedString, to out: URL, formatID: String) throws {
        if formatID == "doc-pdf" { return try writePDF(text, to: out) }
        guard let type = docTypes[formatID] else { throw ConvertError("Unsupported document format.") }
        let range = NSRange(location: 0, length: text.length)
        if type == .plain {
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        } else {
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: out)
        }
    }

    @MainActor static func document(_ input: URL, to out: URL, formatID: String) throws {
        try writeDocument(try readDocument(input), to: out, formatID: formatID)
    }

    @MainActor static func writePDF(_ text: NSAttributedString, to out: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 612, height: 792)
        for side in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: side] = 54 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ConvertError("Couldn't render the PDF.") }
    }

    // MARK: PDF

    static func pdfToImages(_ input: URL, out: URL, format: Format, options: Options) throws -> URL {
        guard let doc = PDFDocument(url: input), doc.pageCount > 0 else { throw ConvertError("Couldn't open the PDF.") }
        let ext = format.ext
        let uti = utiFor[ext]!
        let dpi = [Quality.small: 100.0, .balanced: 150, .high: 220, .maximum: 300][options.quality]!
        let single = doc.pageCount == 1
        let folder = out.deletingPathExtension()
        if !single { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = dpi / 72
            let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let cg = ctx.makeImage() else { continue }
            let target = single ? out : folder.appendingPathComponent(String(format: "Page %03d.\(ext)", i + 1))
            guard let dest = CGImageDestinationCreateWithURL(target as CFURL, uti as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: options.quality.lossy] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return single ? out : folder
    }

    @MainActor static func pdfToText(_ input: URL, to out: URL, formatID: String) throws {
        guard let doc = PDFDocument(url: input) else { throw ConvertError("Couldn't open the PDF.") }
        let combined = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let text = page.attributedString, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combined.append(text)
            } else {
                // A scanned page has no text layer; read it with on-device OCR instead.
                combined.append(NSAttributedString(string: ocr(page), attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
            if i < doc.pageCount - 1 { combined.append(NSAttributedString(string: "\n\n")) }
        }
        // PDF text can carry control characters (form feeds etc.) that are illegal in DOCX/ODT XML
        // and make Word or Pages open an empty document.
        combined.mutableString.replaceOccurrences(of: controlCharacters, with: "",
                                                  options: .regularExpression, range: NSRange(location: 0, length: combined.length))
        guard !combined.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConvertError("Couldn't find any text in this PDF.")
        }
        if formatID == "pdf-txt" {
            try combined.string.write(to: out, atomically: true, encoding: .utf8)
        } else {
            try writeDocument(combined, to: out, formatID: formatID)
        }
    }

    static func ocr(_ page: PDFPage) -> String {
        guard let cg = render(page, scale: 3) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: Data

    static func data(_ input: URL, to out: URL, formatID: String) throws {
        let raw = try Data(contentsOf: input)
        let value: Any
        switch input.pathExtension.lowercased() {
        case "json": value = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        case "plist": value = try PropertyListSerialization.propertyList(from: raw, format: nil)
        case "csv", "tsv":
            let rows = parseRows(String(decoding: raw, as: UTF8.self), separator: input.pathExtension.lowercased() == "tsv" ? "\t" : ",")
            if formatID == "xlsx" { return try Spreadsheet.writeXLSX([.init(name: "Sheet1", rows: rows)], to: out) }
            value = records(rows)
        default: throw ConvertError("Unsupported data file.")
        }

        switch formatID {
        case "json":
            let clean = jsonSafe(value)
            let data = try JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            try data.write(to: out)
        case "plist", "bplist":
            let data = try PropertyListSerialization.data(fromPropertyList: plistSafe(value),
                format: formatID == "plist" ? .xml : .binary, options: 0)
            try data.write(to: out)
        case "csv", "tsv":
            try Spreadsheet.delimited(try table(value), formatID == "tsv" ? "\t" : ",").write(to: out, atomically: true, encoding: .utf8)
        case "xlsx":
            try Spreadsheet.writeXLSX([.init(name: "Sheet1", rows: try table(value))], to: out)
        default: throw ConvertError("Unsupported data format.")
        }
    }

    static func parseRows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r" { row.append(field); field = ""; rows.append(row); row = [] }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        rows.removeAll { $0 == [""] }
        return rows
    }

    /// Rows with a header line → one record per row.
    static func records(_ rows: [[String]]) -> [[String: String]] {
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { values in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { i, key in (key, i < values.count ? values[i] : "") })
        }
    }

    /// Records (or a dictionary holding them) → a header row plus one row per record.
    static func table(_ value: Any) throws -> [[String]] {
        let rows: [[String: Any]]
        if let array = value as? [[String: Any]] { rows = array }
        else if let dict = value as? [String: Any], let array = dict.values.first(where: { $0 is [[String: Any]] }) as? [[String: Any]] { rows = array }
        else if let dict = value as? [String: Any] { rows = [dict] }
        else { throw ConvertError("A table needs a list of records (an array of objects).") }

        var columns: [String] = []
        for row in rows { for key in row.keys.sorted() where !columns.contains(key) { columns.append(key) } }
        func cell(_ v: Any?) -> String {
            guard let v else { return "" }
            if let str = v as? String { return str }
            if v is [Any] || v is [String: Any], let d = try? JSONSerialization.data(withJSONObject: jsonSafe(v)) {
                return String(decoding: d, as: UTF8.self)
            }
            return "\(v)"
        }
        return [columns] + rows.map { row in columns.map { cell(row[$0]) } }
    }

    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let data as Data: return data.base64EncodedString()
        default: return value
        }
    }

    static func plistSafe(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.compactMapValues { $0 is NSNull ? nil : plistSafe($0) }
        case let a as [Any]: return a.filter { !($0 is NSNull) }.map(plistSafe)
        default: return value
        }
    }

    // MARK: Subtitles

    static func subtitles(_ input: URL, to out: URL, formatID: String) throws {
        let text = try String(contentsOf: input, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        // A cue is any blank-line-separated block with a "-->" timing line; this skips WEBVTT/NOTE/STYLE blocks.
        var cues: [(start: String, end: String, lines: [String])] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            cues.append((parts[0].trimmingCharacters(in: .whitespaces), end, Array(lines[(i + 1)...])))
        }
        guard !cues.isEmpty else { throw ConvertError("No subtitle cues found.") }

        func stamp(_ t: String, _ separator: String) -> String {
            var t = t.replacingOccurrences(of: ",", with: ".")
            if t.split(separator: ":").count == 2 { t = "00:" + t }   // VTT allows mm:ss.mmm
            return t.replacingOccurrences(of: ".", with: separator)
        }
        func strip(_ line: String, keepBasic: Bool) -> String {
            let pattern = keepBasic ? "<(?!/?(?:i|b|u)>)[^>]+>" : "<[^>]+>"
            return line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        let output: String
        switch formatID {
        case "srt":
            output = cues.enumerated().map { i, c in
                "\(i + 1)\n\(stamp(c.start, ",")) --> \(stamp(c.end, ","))\n" + c.lines.map { strip($0, keepBasic: true) }.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        case "vtt":
            output = "WEBVTT\n\n" + cues.map { c in
                "\(stamp(c.start, ".")) --> \(stamp(c.end, "."))\n" + c.lines.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        default:
            output = cues.flatMap(\.lines).map { strip($0, keepBasic: false) }.joined(separator: "\n") + "\n"
        }
        try output.write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: Archives

    static let doubleExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz4"]

    static func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        for ext in doubleExtensions where name.lowercased().hasSuffix("." + ext) {
            return String(name.dropLast(ext.count + 1))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Packs one or more files/folders into a single archive. Several items become "Archive.zip".
    static func compress(_ items: [URL], as format: Format, options: Options, baseName: String? = nil) async throws -> URL {
        guard let first = items.first else { throw ConvertError("Nothing to compress.") }
        let folder = options.outputFolder ?? first.deletingLastPathComponent()
        let base = baseName ?? (items.count == 1 ? first.lastPathComponent : "Archive")
        let out = uniqueURL(in: folder, base: base, ext: format.ext)
        var args = ["-c", "-f", out.path, "--exclude", ".DS_Store", "--exclude", "__MACOSX"]
        switch format.id {
        case "zip": args += ["--format", "zip"]
        case "7z": args += ["--format", "7zip"]
        case "tgz": args += ["-z"]
        case "txz": args += ["-J"]
        case "tbz": args += ["-j"]
        default: break
        }
        for item in items { args += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent] }
        // COPYFILE_DISABLE keeps macOS from adding "._" resource-fork files.
        try await run("/usr/bin/tar", args, env: ["COPYFILE_DISABLE": "1"])
        return out
    }

    /// Unpacks like Archive Utility: a lone top-level item lands next to the archive, otherwise a folder is made.
    static func extract(_ input: URL, into outputFolder: URL?) async throws -> URL {
        let fm = FileManager.default
        let parent = outputFolder ?? input.deletingLastPathComponent()
        let base = archiveBaseName(input)
        let staging = parent.appendingPathComponent(".elconvo-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let contents = try await unpack(input, into: staging)
        let target: URL
        let source: URL
        if contents.count == 1 {
            source = contents[0]
            target = uniqueURL(in: parent, base: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
        } else {
            source = staging
            target = uniqueURL(in: parent, base: base, ext: "")
        }
        try fm.moveItem(at: source, to: target)
        return target
    }

    /// Raw unpack into an empty folder; returns the top-level items.
    static func unpack(_ input: URL, into staging: URL) async throws -> [URL] {
        let fm = FileManager.default
        let base = archiveBaseName(input)
        let name = input.lastPathComponent.lowercased()
        let isTarball = doubleExtensions.contains { name.hasSuffix("." + $0) } || ["tgz", "tbz", "tbz2", "txz"].contains(input.pathExtension.lowercased())
        switch input.pathExtension.lowercased() {
        case "aar":
            try await run("/usr/bin/aa", ["extract", "-i", input.path, "-d", staging.path])
        case "gz" where !isTarball:
            try await run("/usr/bin/gunzip", ["-c", input.path], stdout: staging.appendingPathComponent(base))
        case "bz2" where !isTarball:
            try await run("/usr/bin/bunzip2", ["-c", input.path], stdout: staging.appendingPathComponent(base))
        default:
            try await run("/usr/bin/tar", ["-x", "-f", input.path, "-C", staging.path])
        }

        try? fm.removeItem(at: staging.appendingPathComponent("__MACOSX"))
        let contents = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !contents.isEmpty else { throw ConvertError("The archive is empty.") }
        return contents
    }

    /// Converts one archive format into another by unpacking to a temp folder and packing again.
    static func repack(_ input: URL, as format: Format, options: Options) async throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("elconvo-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let items = try await unpack(input, into: temp)
        var opts = options
        opts.outputFolder = options.outputFolder ?? input.deletingLastPathComponent()
        return try await compress(items, as: format, options: opts, baseName: archiveBaseName(input))
    }

    // MARK: Processes

    static func run(_ path: String, _ args: [String], env: [String: String] = [:], stdout: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try runSync(path, args, env: env, stdout: stdout); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    static func runSync(_ path: String, _ args: [String], env: [String: String] = [:], stdout: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let errPipe = Pipe()
        p.standardError = errPipe
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: stdout)
        } else {
            p.standardOutput = FileHandle.nullDevice
        }
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = URL(fileURLWithPath: path).lastPathComponent
            throw ConvertError(msg.isEmpty ? "\(tool) failed (code \(p.terminationStatus))." : "\(tool): \(msg.split(separator: "\n").last ?? "")")
        }
    }
}

// MARK: - Model

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable { case ready, working, done(URL), failed(String) }
    let id = UUID()
    let url: URL
    let kind: Kind
    let size: Int64
    @Published var format: Format?
    @Published var state: State = .ready

    init(url: URL) {
        self.url = url
        kind = Kind.of(url)
        size = Int64(Ops.fileSize(url))
        format = Formats.defaultOutput(for: kind, ext: url.pathExtension.lowercased())
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var jobs: [Job] = []
    @Published var options = Options()
    @Published var isConverting = false

    var kindsPresent: [Kind] { Kind.allCases.filter { k in jobs.contains { $0.kind == k } } }
    var pendingCount: Int { jobs.filter { $0.state == .ready && $0.format != nil }.count }

    func add(_ urls: [URL]) {
        let existing = Set(jobs.map(\.url))
        jobs += urls.filter { !existing.contains($0) && FileManager.default.fileExists(atPath: $0.path) }.map(Job.init)
    }

    /// Replaces a folder row with one row per file inside it.
    func expand(_ job: Job) {
        let walker = FileManager.default.enumerator(at: job.url, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var files: [URL] = []
        while let f = walker?.nextObject() as? URL {
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(f) }
        }
        jobs.removeAll { $0.id == job.id }
        add(files)
    }

    func setAll(_ kind: Kind, to format: Format) {
        for job in jobs where job.kind == kind && job.state != .working {
            job.format = format
            job.state = .ready
        }
    }

    func convertAll() async {
        isConverting = true
        defer { isConverting = false }
        let work = jobs.filter { $0.state == .ready && $0.format != nil }.map { ($0, $0.url, $0.format!) }
        let options = options
        // A few at a time: images are quick, video is CPU-bound.
        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            func next() -> Bool {
                guard let (job, url, format) = iterator.next() else { return false }
                group.addTask {
                    await MainActor.run { job.state = .working }
                    let result: Job.State
                    do { result = .done(try await Converter.convert(url, to: format, options: options)) }
                    catch { result = .failed(error.localizedDescription) }
                    await MainActor.run {
                        job.state = result
                        if case .done = result { Donation.recordUse() }
                    }
                }
                return true
            }
            for _ in 0..<3 { if !next() { break } }
            while await group.next() != nil { _ = next() }
        }
        NSSound(named: "Glass")?.play()
    }

    /// Packs every row into one archive.
    func compressAll(as format: Format) async {
        isConverting = true
        defer { isConverting = false }
        do {
            let out = try await Converter.compress(jobs.map(\.url), as: format, options: options)
            NSSound(named: "Glass")?.play()
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func clear(onlyFinished: Bool) {
        jobs.removeAll { job in
            if !onlyFinished { return job.state != .working }
            if case .done = job.state { return true }
            return false
        }
    }
}

// MARK: - Main window

/// Stand-in for @State, whose macro plugin isn't in the Command Line Tools.
final class Flag: ObservableObject { @Published var on = false }

let accent = Color(red: 1.0, green: 0.55, blue: 0.1)

func chooseFiles() -> [URL] {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    return panel.runModal() == .OK ? panel.urls : []
}

struct ContentView: View {
    @ObservedObject var store = Store.shared
    @StateObject private var drop = Flag()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.jobs.isEmpty { emptyState } else { jobList }
            Divider()
            optionsBar
        }
        .frame(minWidth: 820, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: $drop.on) { providers in
            loadURLs(providers) { store.add($0) }
            return true
        }
        .overlay {
            if drop.on && !store.jobs.isEmpty {
                RoundedRectangle(cornerRadius: 14).strokeBorder(accent, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Button { store.add(chooseFiles()) } label: { Label("Add Files…", systemImage: "plus") }
            if !store.jobs.isEmpty {
                Menu {
                    ForEach(Formats.archiveOut) { f in
                        Button(f.label) { Task { await store.compressAll(as: f) } }
                    }
                } label: { Label("Compress All Into One", systemImage: "archivebox") }
                    .fixedSize()
                Text("Set all").foregroundStyle(.secondary).padding(.leading, 6)
                ForEach(store.kindsPresent, id: \.self) { kind in
                    Menu(kind.rawValue) {
                        ForEach(Formats.conversions(for: kind)) { f in formatButton(kind, f) }
                        Divider()
                        ForEach(Formats.archiving(for: kind)) { f in formatButton(kind, f) }
                    }
                    .fixedSize()
                }
            }
            Spacer()
            Menu {
                Button("Remove Finished") { store.clear(onlyFinished: true) }
                Button("Remove All") { store.clear(onlyFinished: false) }
            } label: { Label("Clear", systemImage: "trash") }
                .fixedSize()
                .disabled(store.jobs.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    func formatButton(_ kind: Kind, _ f: Format) -> some View {
        Button(f.menuLabel) { store.setAll(kind, to: f) }
            .disabled(!Tools.has(f.needs))
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(accent.gradient).frame(width: 96, height: 96)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
            }
            Text("Drop files to convert").font(.title.weight(.semibold))
            Text("Images · RAW · Audio · Video · Documents · PDF · 3D · Subtitles · JSON/CSV · ZIP/7z/RAR/TAR")
                .foregroundStyle(.secondary)
            Text("Tip: hold ⇧ while dragging a file anywhere for the format wheel, or ⌥⇧ for the tools wheel.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Choose Files…") { store.add(chooseFiles()) }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(accent)
            extrasNote
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(drop.on ? accent : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(20)
        )
    }

    @ViewBuilder var extrasNote: some View {
        let missing = [(Tool.ffmpeg, Tools.ffmpeg, "MP3, OGG, WebM, MKV, AVI — brew install ffmpeg"),
                       (Tool.magick, Tools.magick, "WebP — brew install imagemagick"),
                       (Tool.dng, Tools.dng, "RAW → DNG — free from adobe.com")].filter { $0.1 == nil }
        if !missing.isEmpty {
            VStack(spacing: 2) {
                ForEach(missing, id: \.0.rawValue) { tool, _, unlocks in
                    Text("Optional: \(tool.rawValue) unlocks \(unlocks)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    var jobList: some View {
        List {
            ForEach(store.jobs) { job in JobRow(job: job) }
                .onDelete { store.jobs.remove(atOffsets: $0) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    var optionsBar: some View {
        HStack(spacing: 14) {
            Picker("Quality", selection: $store.options.quality) {
                ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 170)
            Picker("Image size", selection: $store.options.maxImageSize) {
                Text("Original").tag(0)
                ForEach([4096, 2048, 1600, 1024, 512], id: \.self) { Text("≤ \($0) px").tag($0) }
            }.frame(width: 175)
            Picker("Video", selection: $store.options.videoHeight) {
                Text("Original").tag(0)
                Text("4K").tag(2160); Text("1080p").tag(1080); Text("720p").tag(720); Text("480p").tag(480)
            }.frame(width: 140)
            Toggle("Strip metadata", isOn: $store.options.stripMetadata).toggleStyle(.checkbox)
            Spacer()
            Menu {
                Button("Next to the original") { store.options.outputFolder = nil }
                Button("Choose Folder…") { pickOutputFolder() }
            } label: {
                Label(store.options.outputFolder?.lastPathComponent ?? "Same folder", systemImage: "folder")
            }.fixedSize()
            Button {
                Task { await store.convertAll() }
            } label: {
                if store.isConverting { ProgressView().controlSize(.small).frame(width: 80) }
                else { Text(store.pendingCount > 0 ? "Convert \(store.pendingCount)" : "Convert").frame(minWidth: 80) }
            }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store.isConverting || store.pendingCount == 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK { store.options.outputFolder = panel.url }
    }
}

func loadURLs(_ providers: [NSItemProvider], then handler: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { handler(urls) } }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(job.kind == .folder ? "Folder" : "\(job.kind.rawValue) · \(bytes(job.size))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Picker("", selection: Binding(get: { job.format }, set: { job.format = $0; job.state = .ready })) {
                if job.format == nil { Text("Choose…").tag(Format?.none) }
                let conversions = Formats.conversions(for: job.kind)
                ForEach(conversions) { option($0) }
                if !conversions.isEmpty { Divider() }
                ForEach(Formats.archiving(for: job.kind)) { option($0) }
            }
            .labelsHidden().frame(width: 210)
            .disabled(job.state == .working)
            status.frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
            if job.kind == .folder { Button("Add Folder's Files Instead") { Store.shared.expand(job) } }
            if case .done(let out) = job.state {
                Button("Show Converted in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                Button("Open Converted") { NSWorkspace.shared.open(out) }
            }
            if case .failed(let message) = job.state { Text(message) }
            Divider()
            Button("Remove") { Store.shared.jobs.removeAll { $0.id == job.id } }
        }
    }

    func option(_ f: Format) -> some View {
        Text(f.menuLabel)
            .tag(Optional(f))
            .selectionDisabled(!Tools.has(f.needs))
    }

    @ViewBuilder var status: some View {
        switch job.state {
        case .ready: EmptyView()
        case .working: ProgressView().controlSize(.small)
        case .done(let out):
            Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Image(systemName: "magnifyingglass")
            }.buttonStyle(.borderless).help("Show in Finder: \(out.lastPathComponent)")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
        }
    }
}

// MARK: - App shell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // Development aid: `--snapshot-rename out.png files…` draws the Batch Rename window to an image and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-rename"), args.count > i + 2 {
            Editors.openBatchRename(args[(i + 2)...].map { URL(fileURLWithPath: $0) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let frame = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("Batch") })?.contentView?.superview,
                   let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                exit(0)
            }
            return
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Elconvo"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView())
        window.setFrameAutosaveName("Main")
        window.center()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "Elconvo")
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Shelf.shared.start()
        listenForElxplorer()
        // Spawning ffmpeg to list its encoders takes a moment; do it now rather than inside the first OGG job.
        DispatchQueue.global(qos: .utility).async { _ = Tools.ffmpegEncoders }
        Donation.start()
        offerLoginItemOnce()
        FullDiskAccess.offerIfNeeded()
        // No window on launch: everything happens from the drag wheel.
        JobHUD.notice("Elconvo is running",
                      "Hold ⇧ while dragging a file to convert it. Hold ⌥⇧ for tools.\nThe full window is in the menu bar.")
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // Files dropped on the Dock icon or sent via Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Store.shared.add(urls)
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    // Keep running after the window closes so the shift-drag shelf stays available.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A drag utility is only useful if it's running, so offer to start at login the first time.
    func offerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: "offeredLoginItem") else { return }
        UserDefaults.standard.set(true, forKey: "offeredLoginItem")
        guard SMAppService.mainApp.status != .enabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open Elconvo when you log in?"
        alert.informativeText = "Elconvo waits quietly in the menu bar so the ⇧-drag wheel is always there. You can change this later from the menu bar icon."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { try? SMAppService.mainApp.register() }
    }

    // Finder ▸ right-click ▸ Services (declared under NSServices in Info.plist).
    @objc func showSizeInfo(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.fileURLs
        if !urls.isEmpty { Editors.openInfo(urls) }
    }

    @objc func showMetadata(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        pboard.fileURLs.prefix(6).forEach { Editors.open(.metadata, $0) }
    }

    /// Requests from Elxplorer's right-click menu. They come over a distributed notification, which only apps
    /// on this Mac can send (unlike a URL scheme, which any web page could trigger).
    func listenForElxplorer() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.itzkin.elconvo.command"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let info = note.userInfo, let action = info["action"] as? String,
                      let paths = info["files"] as? [String], !paths.isEmpty else { return }
                let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return }
                let shelf = Shelf.shared
                switch action {
                case "wheel":
                    let point = NSPoint(x: info["x"] as? Double ?? NSEvent.mouseLocation.x, y: info["y"] as? Double ?? NSEvent.mouseLocation.y)
                    shelf.showWheel(for: urls, at: point, tools: (info["tools"] as? Bool) ?? false)
                case "convert":
                    let id = info["format"] as? String ?? ""
                    if let format = id == "extract" ? Formats.extract : Formats.byID(id) { shelf.perform(.convert(format), urls: urls) }
                case "tool":
                    if let op = Op(rawValue: info["op"] as? String ?? "") { shelf.perform(.op(op), urls: urls) }
                default:
                    Store.shared.add(urls)
                    self.showMainWindow()
                }
            }
        }
    }

    @objc func openWindow() { showMainWindow() }
    @objc func grantAccess() { FullDiskAccess.ask(fromMenu: true) }
    @objc func donate() { NSWorkspace.shared.open(Donation.page) }
    @objc func website() { NSWorkspace.shared.open(URL(string: "https://ai.itzkin.com/elconvo.html")!) }
    @objc func addFiles() { showMainWindow(); Store.shared.add(chooseFiles()) }
    @objc func toggleShelf() { Shelf.shared.enabled.toggle() }
    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Elconvo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Elconvo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Elconvo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Files…", action: #selector(addFiles), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Elconvo", action: #selector(openWindow), keyEquivalent: "0")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

extension AppDelegate: NSMenuDelegate {
    // Rebuilt on open so the checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Elconvo", action: #selector(openWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Convert Files…", action: #selector(addFiles), keyEquivalent: "")
        menu.addItem(.separator())
        let shelf = menu.addItem(withTitle: "Shift-Drag Wheel", action: #selector(toggleShelf), keyEquivalent: "")
        shelf.state = Shelf.shared.enabled ? .on : .off
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let access = menu.addItem(withTitle: FullDiskAccess.isGranted ? "Full Disk Access: On" : "Grant Full Disk Access…",
                                  action: #selector(grantAccess), keyEquivalent: "")
        access.state = FullDiskAccess.isGranted ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Support Elconvo on Ko-fi…", action: #selector(donate), keyEquivalent: "")
        menu.addItem(withTitle: "Elconvo Website", action: #selector(website), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(website), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Elconvo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

// MARK: - Entry point
//
// No arguments: the menu bar app. From the terminal:
//   --convert <file> <format-id> [out-folder]   one conversion
//   --tool <tool> <file>... [--background blur|green]   a non-interactive tool
//   --render-wheel <out.png> convert|tools <file>...   draws the wheel (for screenshots)

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        // Development aid: draws the wheel for some files to a PNG, e.g. `--render-wheel out.png tools a.jpg b.jpg`.
        if let i = args.firstIndex(of: "--render-wheel"), args.count > i + 3 {
            MainActor.assumeIsolated {
                let shelf = Shelf.shared
                shelf.urls = args[(i + 3)...].map { URL(fileURLWithPath: $0) }
                shelf.mode = args[i + 2] == "tools" ? .tools : .convert
                shelf.hovered = 1
                shelf.sizeLabel = bytes(shelf.urls.reduce(0) { $0 + SizeItem.measure($1).bytes })
                shelf.thumbnail = NSImage(contentsOf: shelf.urls[0]) ?? NSWorkspace.shared.icon(forFile: shelf.urls[0].path)
                let renderer = ImageRenderer(content: WheelView(animated: false, glass: false)
                    .background(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            exit(0)
        }
        // For Elxplorer: which conversions and tools fit these files, as JSON.
        if let i = args.firstIndex(of: "--list-actions"), args.count > i + 1 {
            let urls = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            let kinds = Set(urls.map(Kind.of))
            let kind = kinds.count == 1 ? kinds.first : nil
            var convert = (kind.map(Formats.conversions(for:)) ?? []).filter { Tools.has($0.needs) }
            convert += Formats.archiving(for: kind ?? .unknown)
            let tools = MainActor.assumeIsolated { Op.available(for: kind, count: urls.count) }
            let json: [String: Any] = [
                "convert": convert.map { ["id": $0.id, "label": $0.label] },
                "tools": tools.map { ["id": $0.rawValue, "title": $0.title] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json) { FileHandle.standardOutput.write(data) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--tool") {
            guard args.count > i + 2, let op = Op(rawValue: args[i + 1]) else {
                let tools = Op.allCases.filter { !$0.interactive }.map(\.rawValue)
                print("usage: Elconvo --tool <tool> <file>...\ntools: \(tools.joined(separator: " "))")
                exit(2)
            }
            var rest = Array(args[(i + 2)...])
            var background: VideoBackground?
            if let b = rest.firstIndex(of: "--background"), b + 1 < rest.count {   // video Remove BG: blur | green
                background = ["blur": .blur, "green": .green][rest[b + 1]] ?? .transparent
                rest.removeSubrange(b...(b + 1))
            }
            let urls = rest.map { URL(fileURLWithPath: $0).standardizedFileURL }
            Task { @MainActor in
                let (outs, errors, notes) = await Ops.perform(op, urls, background: background) { _ in }
                outs.forEach { print($0.path) }
                notes.forEach { print("found: \($0)") }
                errors.forEach { FileHandle.standardError.write(Data("error: \($0)\n".utf8)) }
                exit(errors.isEmpty ? 0 : 1)
            }
            RunLoop.main.run()
        }
        guard let i = args.firstIndex(of: "--convert") else {
            let delegate = MainActor.assumeIsolated { AppDelegate() }
            app.delegate = delegate
            app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
            app.run()
            return
        }
        guard args.count > i + 2, let format = args[i + 2] == "extract" ? Formats.extract : Formats.byID(args[i + 2]) else {
            let ids = Kind.allCases.flatMap { Formats.conversions(for: $0) }.map(\.id) + Formats.archiveOut.map(\.id)
            print("usage: Elconvo --convert <file> <format> [output-folder]\nformats: \(Array(NSOrderedSet(array: ids)).map { "\($0)" }.joined(separator: " "))")
            exit(2)
        }
        let input = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        var options = Options()
        if args.count > i + 3 { options.outputFolder = URL(fileURLWithPath: args[i + 3]) }
        Task { @MainActor in
            do {
                let out = try await Converter.convert(input, to: format, options: options)
                print(out.path); exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
            }
        }
        RunLoop.main.run()
    }
}
