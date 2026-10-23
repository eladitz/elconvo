// Tools for the Option+Shift wheel: compress, fit to size, background removal, crop, trim, speed,
// normalise, PDF merge/split and friends. Each writes a new file beside the original.
// (rotate and redact are reachable from the command line; in the app they live in Adjust and Markup.)

import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Vision
import PDFKit
import Accelerate
import CoreImage

enum Op: String, Identifiable, CaseIterable {
    case compress, fitSize, removeBackground, crop, adjust, markup, rotate, redact, metadata, readQR, collage, toPDF
    case trim, snapshot, faster, slower, mute, join
    case normalize, mono, stereo
    case merge, split, rotatePages, organize
    case info, rename, batchRename, translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: "Compress"
        case .fitSize: "Fit Size"
        case .adjust: "Adjust"
        case .markup: "Markup"
        case .organize: "Organize"
        case .info: "Size & Info"
        case .rename: "Rename"
        case .batchRename: "Batch Rename"
        case .translate: "Translate"
        case .removeBackground: "Remove BG"
        case .crop: "Crop"
        case .rotate, .rotatePages: "Rotate"
        case .redact: "Redact"
        case .metadata: "Metadata"
        case .readQR: "Read QR"
        case .collage: "Collage"
        case .toPDF: "Make PDF"
        case .trim: "Trim"
        case .snapshot: "Snapshot"
        case .faster: "2× Speed"
        case .slower: "½ Speed"
        case .mute: "Mute"
        case .join: "Join"
        case .normalize: "Normalize"
        case .mono: "Mono"
        case .stereo: "Stereo"
        case .merge: "Merge"
        case .split: "Split Pages"
        }
    }

    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .fitSize: "scalemass"
        case .adjust: "slider.horizontal.3"
        case .markup: "pencil.tip.crop.circle"
        case .organize: "square.grid.3x2"
        case .info: "info.circle"
        case .rename: "character.cursor.ibeam"
        case .batchRename: "list.number"
        case .translate: "translate"
        case .removeBackground: "person.crop.rectangle"
        case .crop: "crop"
        case .rotate, .rotatePages: "rotate.right"
        case .redact: "eye.slash"
        case .metadata: "tag"
        case .readQR: "qrcode.viewfinder"
        case .collage: "square.grid.2x2"
        case .toPDF: "doc.richtext"
        case .trim: "timeline.selection"
        case .snapshot: "camera"
        case .faster: "hare"
        case .slower: "tortoise"
        case .mute: "speaker.slash"
        case .join, .merge: "link"
        case .normalize: "waveform"
        case .mono: "speaker.wave.1"
        case .stereo: "speaker.wave.2"
        case .split: "scissors"
        }
    }

    /// Works on all the dropped files together rather than one by one.
    var combines: Bool { [.collage, .toPDF, .join, .merge, .info, .batchRename].contains(self) }
    /// Opens a window instead of running straight away.
    var interactive: Bool { [.crop, .adjust, .markup, .trim, .snapshot, .metadata, .organize, .info, .rename, .batchRename, .translate].contains(self) }
    /// Editors that work on one file at a time; left off the wheel when several files are dragged.
    var singleFile: Bool { [.crop, .adjust, .markup, .trim, .snapshot, .organize, .split, .rename].contains(self) }

    static func available(for kind: Kind?, count: Int) -> [Op] {
        let multi = count > 1
        var ops: [Op]
        switch kind {
        case .image: ops = [.compress, .fitSize, .removeBackground, .crop, .adjust, .markup, .metadata, .readQR] + (multi ? [.collage, .toPDF] : [.toPDF])
        case .raw: ops = [.compress, .fitSize, .crop, .adjust, .metadata]
        case .video: ops = [.compress, .fitSize, .removeBackground, .trim, .crop, .snapshot, .faster, .slower, .mute, .metadata] + (multi ? [.join] : [])
        case .audio: ops = [.compress, .fitSize, .trim, .normalize, .mono, .stereo, .faster, .metadata] + (multi ? [.join] : [])
        case .pdf: ops = [.translate, .compress, .fitSize, .organize, .split, .rotatePages, .metadata, .readQR] + (multi ? [.merge] : [])
        default: ops = []
        }
        if multi { ops.removeAll { $0.singleFile || $0 == .readQR } }
        // Several items, folders or a mix: the size breakdown is the useful tool.
        if multi || ops.isEmpty { ops.insert(.info, at: 0) }
        ops.append(multi ? .batchRename : .rename)   // any kind of file or folder
        return ops
    }
}

enum Ops {
    // MARK: Running

    @MainActor
    static func run(_ op: Op, _ urls: [URL], hud: JobHUD, target: Int64? = nil, background: VideoBackground? = nil) async {
        // Long jobs (video) report their own steps, e.g. "frame 120 of 900".
        let step: @Sendable (String) -> Void = { text in Task { @MainActor in hud.current = text } }
        let (outs, errors, notes) = await Converter.$report.withValue(step) {
            await perform(op, urls, target: target, background: background) { name in
                if let name { hud.current = name } else { hud.done += 1 }
            }
        }
        report(op, urls, outs: outs, errors: errors, notes: notes, hud: hud)
    }

    /// Runs a tool over the files. `progress` gets each file name as it starts, then nil when it's done.
    @MainActor
    static func perform(_ op: Op, _ urls: [URL], target: Int64? = nil, background: VideoBackground? = nil,
                        progress: (String?) -> Void) async -> (outs: [URL], errors: [String], notes: [String]) {
        var outs: [URL] = [], errors: [String] = [], notes: [String] = []
        if op.combines {
            progress("\(urls.count) files")
            do {
                switch op {
                case .collage: outs.append(try await collage(urls))
                case .toPDF: outs.append(try await imagesToPDF(urls))
                case .join: outs.append(try await join(urls))
                case .merge: outs.append(try await mergePDFs(urls))
                default: break
                }
            } catch { errors.append(error.localizedDescription) }
        } else {
            for url in urls {
                progress(url.lastPathComponent)
                do {
                    switch op {
                    case .compress: outs.append(try await compress(url))
                    case .fitSize: outs.append(try await fitSize(url, target ?? Int64(fileSize(url) / 2)))
                    case .removeBackground:
                        outs.append(Kind.of(url) == .video ? try await VideoMatte.run(url, background: background ?? .transparent)
                                                           : try await removeBackground(url))
                    case .rotate: outs.append(try await rotateImage(url))
                    case .redact: outs.append(try await redact(url))
                    case .readQR: notes += try await readCodes(url)
                    case .faster: outs.append(try await changeSpeed(url, factor: 2))
                    case .slower: outs.append(try await changeSpeed(url, factor: 0.5))
                    case .mute: outs.append(try await mute(url))
                    case .normalize: outs.append(try await normalize(url))
                    case .mono: outs.append(try await channels(url, 1))
                    case .stereo: outs.append(try await channels(url, 2))
                    case .split: outs.append(try await splitPDF(url))
                    case .rotatePages: outs.append(try await rotatePDF(url))
                    default: break
                    }
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                progress(nil)
            }
        }
        return (outs, errors, notes)
    }

    @MainActor
    private static func report(_ op: Op, _ urls: [URL], outs: [URL], errors: [String], notes: [String], hud: JobHUD) {
        var errors = errors
        var note: String?
        if op == .readQR {
            if notes.isEmpty && errors.isEmpty { errors.append("No QR codes or barcodes found.") }
            if !notes.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notes.joined(separator: "\n"), forType: .string)
                note = notes.joined(separator: "\n") + "\n\nCopied to the clipboard."
            }
        } else if op == .compress || op == .fitSize, !outs.isEmpty {
            let before = urls.reduce(0) { $0 + fileSize($1) }, after = outs.reduce(0) { $0 + fileSize($1) }
            let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            hud.title = "Compressed \(bytes(Int64(before))) → \(bytes(Int64(after))) (−\(saved)%)"
        }
        hud.finish(outs: outs, errors: errors, note: note)
    }

    // MARK: Helpers

    /// Every finished job ends the same way: it counts toward the donation prompt and the editor that
    /// made it (if any) closes. The result lands beside the original, in the folder the user is already
    /// looking at, so no Finder window is opened; the progress card has "Show in Finder" for that.
    @MainActor
    static func delivered(_ outs: [URL], closing window: NSWindow? = nil) {
        outs.forEach { _ in Donation.recordUse() }
        window?.close()
    }

    static func fileSize(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// "name suffix.ext" beside the original, never overwriting anything.
    static func sibling(_ url: URL, _ suffix: String, ext: String? = nil) -> URL {
        Converter.uniqueURL(in: url.deletingLastPathComponent(),
                            base: "\(url.deletingPathExtension().lastPathComponent) \(suffix)",
                            ext: ext ?? url.pathExtension)
    }

    static func loadUpright(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        let raw = Kind.of(url) == .raw
        let (cg, props) = try Converter.loadImage(url, raw: raw, sixteenBit: false)
        return (Converter.applyOrientation(cg, props: props, alreadyApplied: raw), props)
    }

    /// Where an edited image goes: its own format when we can write it, otherwise JPEG (or PNG for transparency).
    static func editedURL(_ url: URL, _ suffix: String, transparent: Bool = false) -> URL {
        if transparent { return sibling(url, suffix, ext: "png") }
        let ext = url.pathExtension.lowercased()
        let writable = ["jpg", "jpeg", "png", "heic", "avif", "tif", "tiff", "gif", "bmp", "psd"].contains(ext)
            || (ext == "webp" && Tools.magick != nil)
        return sibling(url, suffix, ext: writable ? url.pathExtension : "jpg")
    }

    static func save(_ image: CGImage, to out: URL, quality: Double = 0.92, props: [CFString: Any] = [:]) throws {
        var ext = out.pathExtension.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        if ext == "tif" { ext = "tiff" }
        if ext == "webp", let magick = Tools.magick {
            try Converter.withTempFile(ext: "png") { png in
                try save(image, to: png)
                try Converter.runSync(magick, [png.path, "-quality", "\(Int(quality * 100))", out.path])
            }
            return
        }
        let flat = ext == "jpg" || ext == "bmp" ? Converter.flattened(image) : image
        guard let uti = Converter.utiFor[ext],
              let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil)
        else { throw ConvertError("Can't write .\(ext) images.") }
        var options = props
        options[kCGImageDestinationLossyCompressionQuality] = quality
        options[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(dest, flat, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn't save the image.") }
    }

    /// The camera, location, caption and copyright blocks worth carrying into a converted image.
    static func keptMetadata(_ props: [CFString: Any]) -> [CFString: Any] {
        let keys = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary]
        return props.filter { keys.contains($0.key) }
    }

    /// Apple's own movie containers, which AVFoundation writes directly.
    static let movieExtensions: Set<String> = ["mov", "mp4", "m4v"]
    /// The ones AVFoundation can rewrite with new or no metadata.
    static let taggableExtensions = movieExtensions.union(["m4a"])

    /// Keep the original's container when AVFoundation can write it, otherwise use `fallback`.
    static func movieExtension(_ url: URL, else fallback: String) -> String {
        movieExtensions.contains(url.pathExtension.lowercased()) ? url.pathExtension : fallback
    }

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        case "m4a": .m4a
        default: .mov
        }
    }

    static func export(_ asset: AVAsset, preset: String, to out: URL, timeRange: CMTimeRange? = nil,
                       stripMetadata: Bool = false, keepPitch: Bool = false,
                       videoComposition: AVVideoComposition? = nil, metadata: [AVMetadataItem]? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError("This file can't be exported.")
        }
        session.outputURL = out
        session.outputFileType = fileType(for: out)
        if let timeRange { session.timeRange = timeRange }
        if stripMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        if keepPitch { session.audioTimePitchAlgorithm = .spectral }
        if let videoComposition { session.videoComposition = videoComposition }
        if let metadata { session.metadata = metadata }
        await session.export()
        if let error = session.error { throw error }
        guard session.status == .completed else { throw ConvertError("The export didn't finish.") }
    }

    /// Lays files end to end in one composition, optionally dropping their sound or picture.
    static func composition(_ urls: [URL], video: Bool = true, audio: Bool = true) async throws -> (AVMutableComposition, hasVideo: Bool) {
        let comp = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?, audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isReadable) else { throw ConvertError("macOS can't read \(url.lastPathComponent).") }
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if video, let track = try await asset.loadTracks(withMediaType: .video).first {
                if videoTrack == nil {
                    videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    videoTrack?.preferredTransform = try await track.load(.preferredTransform)
                }
                try videoTrack?.insertTimeRange(range, of: track, at: cursor)
            }
            if audio, let track = try await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioTrack?.insertTimeRange(range, of: track, at: cursor)
            }
            cursor = cursor + duration
        }
        return (comp, videoTrack != nil)
    }

    /// The afconvert format that keeps an audio file in its own container, or M4A when we can't write that.
    static func audioTarget(_ url: URL) -> (id: String, ext: String) {
        switch url.pathExtension.lowercased() {
        case "wav": ("wav", "wav")
        case "aif", "aiff", "aifc": ("aiff", "aiff")
        case "flac": ("flac", "flac")
        case "caf": ("caf", "caf")
        case "aac": ("aac", "aac")
        default: ("m4a-aac", "m4a")
        }
    }

    // MARK: Compress

    static func compress(_ url: URL) async throws -> URL {
        let out: URL
        switch Kind.of(url) {
        case .image, .raw:
            let (image, props) = try loadUpright(url)
            let small = Converter.resized(image, maxSide: 2560)
            let ext = url.pathExtension.lowercased()
            let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(small.alphaInfo)
            let outExt = ["heic", "avif", "webp"].contains(ext) ? ext : (ext == "png" && alpha ? "png" : "jpg")
            out = sibling(url, "compressed", ext: outExt)
            if outExt == "png", let magick = Tools.magick {
                // 256-colour quantisation is where PNG savings come from.
                try Converter.withTempFile(ext: "png") { tmp in
                    try save(small, to: tmp)
                    try Converter.runSync(magick, [tmp.path, "-strip", "-colors", "256", "-define", "png:compression-level=9", out.path])
                }
            } else {
                try save(small, to: out, quality: 0.6, props: keptMetadata(props))
            }
        case .video:
            let ext = movieExtension(url, else: "mp4")
            out = sibling(url, "compressed", ext: ext)
            try await Converter.run("/usr/bin/avconvert", ["--source", url.path, "--output", out.path,
                                                           "--preset", "PresetHEVC1920x1080", "--replace"])
        case .audio:
            out = sibling(url, "compressed", ext: "m4a")
            try await Converter.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "96000", "-s", "1", url.path, out.path])
        case .pdf:
            guard let doc = PDFDocument(url: url) else { throw ConvertError("Couldn't open the PDF.") }
            out = sibling(url, "compressed")
            guard doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            else { throw ConvertError("Couldn't write the PDF.") }
        default:
            throw ConvertError("Nothing to compress here.")
        }
        if fileSize(out) >= fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError("Already as small as it gets.")
        }
        return out
    }

    // MARK: Fit to an exact size

    /// Parses "5", "500 KB", "2.5mb", "1 GB" (megabytes when no unit is given).
    static func parseSize(_ text: String) -> Int64? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1)]
        for (suffix, scale) in units where s.hasSuffix(suffix) {
            return Double(s.dropLast(suffix.count)).map { Int64($0 * scale) }
        }
        return Double(s).map { Int64($0 * 1e6) }
    }

    static func encode(_ image: CGImage, uti: String, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Makes a copy at or just under `target` bytes.
    static func fitSize(_ url: URL, _ target: Int64) async throws -> URL {
        let mb = bytes(target)
        if Int64(fileSize(url)) <= target { throw ConvertError("Already under \(mb).") }
        switch Kind.of(url) {
        case .image, .raw:
            var image = try loadUpright(url).0
            let ext = url.pathExtension.lowercased()
            let outExt = ["heic", "avif"].contains(ext) ? ext : "jpg"
            let uti = Converter.utiFor[outExt]!
            // Search quality first; only when even the lowest won't fit, shrink the picture and try again.
            for _ in 0..<10 {
                var lo = 0.05, hi = 0.95, best: Data?
                for _ in 0..<7 {
                    let q = (lo + hi) / 2
                    guard let data = encode(image, uti: uti, quality: q) else { break }
                    if Int64(data.count) <= target { best = data; lo = q } else { hi = q }
                }
                if let best {
                    let out = sibling(url, "fit", ext: outExt)
                    try best.write(to: out)
                    return out
                }
                image = Converter.resized(image, maxSide: Int(Double(max(image.width, image.height)) * 0.75))
            }
            throw ConvertError("Couldn't get it down to \(mb).")
        case .video:
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            if Tools.ffmpeg != nil {
                let totalKbps = Double(target) * 8 / 1000 / seconds * 0.95
                let audio = totalKbps > 600 ? 128.0 : 64.0
                let video = Int(totalKbps - audio)
                guard video >= 80 else { throw ConvertError("\(mb) is too small for a \(Int(seconds))-second video.") }
                let out = sibling(url, "fit", ext: "mp4")
                try await Converter.ffmpeg(url, out: out, ["-c:v", "libx264", "-b:v", "\(video)k", "-maxrate", "\(video)k",
                                                          "-bufsize", "\(video * 2)k", "-pix_fmt", "yuv420p",
                                                          "-c:a", "aac", "-b:a", "\(Int(audio))k", "-movflags", "+faststart"])
                return out
            }
            // Without ffmpeg, step down Apple's presets until one fits.
            for preset in ["PresetHEVC1920x1080", "Preset1280x720", "Preset960x540", "Preset640x480"] {
                let out = sibling(url, "fit", ext: "mp4")
                try await Converter.run("/usr/bin/avconvert", ["--source", url.path, "--output", out.path, "--preset", preset, "--replace"])
                if Int64(fileSize(out)) <= target { return out }
                try? FileManager.default.removeItem(at: out)
            }
            throw ConvertError("Couldn't reach \(mb) with the built-in encoder; install ffmpeg for exact sizes.")
        case .audio:
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            let bitrate = Int(Double(target) * 8 / seconds * 0.96)
            guard bitrate >= 24_000 else { throw ConvertError("\(mb) is too small for this much audio.") }
            let out = sibling(url, "fit", ext: "m4a")
            try await Converter.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "\(min(bitrate, 320_000))", url.path, out.path])
            return out
        case .pdf:
            guard let doc = PDFDocument(url: url) else { throw ConvertError("Couldn't open the PDF.") }
            let out = sibling(url, "fit")
            doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            if Int64(fileSize(out)) <= target { return out }
            // Still too big: re-draw each page as a picture at falling resolutions.
            for dpi in [150.0, 110, 80, 60] {
                let flat = PDFDocument()
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let size = page.bounds(for: .mediaBox).size
                    let pixels = NSSize(width: size.width * dpi / 72, height: size.height * dpi / 72)
                    let picture = page.thumbnail(of: pixels, for: .mediaBox)
                    picture.size = size   // keep the page dimensions; the pixels carry the resolution
                    if let p = PDFPage(image: picture) { flat.insert(p, at: flat.pageCount) }
                }
                flat.write(to: out, withOptions: [.saveImagesAsJPEGOption: true])
                if Int64(fileSize(out)) <= target { return out }
            }
            try? FileManager.default.removeItem(at: out)
            throw ConvertError("Couldn't get the PDF down to \(mb).")
        default:
            throw ConvertError("Nothing to shrink here.")
        }
    }

    // MARK: Images

    static func removeBackground(_ url: URL) async throws -> URL {
        let (image, _) = try loadUpright(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConvertError("Couldn't find a subject to keep.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cut = Converter.ciContext.createCGImage(ci, from: ci.extent) else { throw ConvertError("Couldn't build the cut-out.") }
        let out = editedURL(url, "no background", transparent: true)
        try save(cut, to: out)
        return out
    }

    static func rotateImage(_ url: URL) async throws -> URL {
        let (image, props) = try loadUpright(url)
        let ci = CIImage(cgImage: image).oriented(.right)
        guard let rotated = Converter.ciContext.createCGImage(ci, from: ci.extent) else { throw ConvertError("Couldn't rotate.") }
        let out = editedURL(url, "rotated")
        try save(rotated, to: out, props: keptMetadata(props))
        return out
    }

    /// Blacks out every face, line of text and barcode Vision can find. Metadata is dropped too.
    /// Every line of text, face and barcode Vision finds: normalised boxes, bottom-left origin.
    static func sensitiveAreas(in image: CGImage) throws -> [CGRect] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        let faces = VNDetectFaceRectanglesRequest()
        let codes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, faces, codes])
        return (text.results ?? []).map(\.boundingBox) + (faces.results ?? []).map(\.boundingBox) + (codes.results ?? []).map(\.boundingBox)
    }

    static func redact(_ url: URL) async throws -> URL {
        let (image, _) = try loadUpright(url)
        let boxes = try sensitiveAreas(in: image)
        guard !boxes.isEmpty else { throw ConvertError("Found no text, faces or codes to redact.") }

        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Couldn't draw the redaction.") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(.black)
        for box in boxes {   // Vision boxes are normalised with a bottom-left origin, same as CGContext
            let r = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
            ctx.fill(r.insetBy(dx: -r.height * 0.15, dy: -r.height * 0.15))
        }
        let out = editedURL(url, "redacted")
        try save(ctx.makeImage()!, to: out)
        return out
    }

    static func readCodes(_ url: URL) async throws -> [String] {
        let image: CGImage
        if Kind.of(url) == .pdf, let page = PDFDocument(url: url)?.page(at: 0) {
            guard let cg = Converter.render(page, scale: 3) else { return [] }
            image = cg
        } else {
            image = try loadUpright(url).0
        }
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static func collage(_ urls: [URL]) async throws -> URL {
        let images = try urls.map { try loadUpright($0).0 }
        let cols = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(cols)))
        let cell: CGFloat = 1200, gap: CGFloat = 24
        let width = CGFloat(cols) * cell + CGFloat(cols + 1) * gap
        let height = CGFloat(rows) * cell + CGFloat(rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError("Couldn't build the collage.") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        for (i, image) in images.enumerated() {
            let col = i % cols, row = i / cols
            let box = CGRect(x: gap + CGFloat(col) * (cell + gap), y: height - CGFloat(row + 1) * (cell + gap), width: cell, height: cell)
            let scale = min(cell / CGFloat(image.width), cell / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            ctx.draw(image, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
        }
        let out = Converter.uniqueURL(in: urls[0].deletingLastPathComponent(), base: "Collage", ext: "jpg")
        try save(ctx.makeImage()!, to: out, quality: 0.88)
        return out
    }

    static func imagesToPDF(_ urls: [URL]) async throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            let image = try loadUpright(url).0
            guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        let first = urls[0]
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Images"
        let out = Converter.uniqueURL(in: first.deletingLastPathComponent(), base: base, ext: "pdf")
        guard doc.write(to: out) else { throw ConvertError("Couldn't write the PDF.") }
        return out
    }

    // MARK: Video & audio

    static func changeSpeed(_ url: URL, factor: Double) async throws -> URL {
        let (comp, hasVideo) = try await composition([url])
        let range = CMTimeRange(start: .zero, duration: comp.duration)
        comp.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(comp.duration, multiplier: 1 / factor))
        let out = sibling(url, factor > 1 ? "2x" : "half speed", ext: hasVideo ? "mp4" : "m4a")
        try await export(comp, preset: hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A,
                         to: out, keepPitch: true)
        return out
    }

    static func mute(_ url: URL) async throws -> URL {
        let (comp, hasVideo) = try await composition([url], audio: false)
        guard hasVideo else { throw ConvertError("There's no picture to keep.") }
        let ext = movieExtension(url, else: "mov")
        let out = sibling(url, "muted", ext: ext)
        try await export(comp, preset: AVAssetExportPresetPassthrough, to: out)
        return out
    }

    static func join(_ urls: [URL]) async throws -> URL {
        let (comp, hasVideo) = try await composition(urls)
        let out = Converter.uniqueURL(in: urls[0].deletingLastPathComponent(), base: "Joined", ext: hasVideo ? "mp4" : "m4a")
        try await export(comp, preset: hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A, to: out)
        return out
    }

    /// Peak-normalises to −1 dBFS.
    static func normalize(_ url: URL) async throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let data = buffer.floatChannelData else { throw ConvertError("Couldn't read the audio.") }
        try file.read(into: buffer)
        let frames = vDSP_Length(buffer.frameLength)
        var peak: Float = 0
        for ch in 0..<Int(format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[ch], 1, &channelPeak, frames)
            peak = max(peak, channelPeak)
        }
        guard peak > 0 else { throw ConvertError("The file is silent.") }
        var gain: Float = 0.891 / peak
        for ch in 0..<Int(format.channelCount) { vDSP_vsmul(data[ch], 1, &gain, data[ch], 1, frames) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writePCM(buffer, to: tmp)
        let target = audioTarget(url)
        let out = sibling(url, "normalized", ext: target.ext)
        try await Converter.audio(tmp, to: out, formatID: target.id, options: Options())
        return out
    }

    // Separate so the writer is closed (deinitialised) before anything reads the file.
    private static func writePCM(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        var settings = buffer.format.settings
        settings[AVLinearPCMIsNonInterleaved] = false   // CAF stores interleaved; saying so avoids a console warning
        let writer = try AVAudioFile(forWriting: url, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }

    static func channels(_ url: URL, _ count: Int) async throws -> URL {
        let target = audioTarget(url)
        let out = sibling(url, count == 1 ? "mono" : "stereo", ext: target.ext)
        let args = Converter.afconvertArgs(target.id, options: Options())!
        try await Converter.run("/usr/bin/afconvert", args + ["-c", "\(count)", url.path, out.path])
        return out
    }

    // MARK: PDF

    static func splitPDF(_ url: URL) async throws -> URL {
        guard let doc = PDFDocument(url: url), doc.pageCount > 1 else { throw ConvertError("Needs a PDF with more than one page.") }
        let folder = Converter.uniqueURL(in: url.deletingLastPathComponent(),
                                         base: url.deletingPathExtension().lastPathComponent + " pages", ext: "")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent(String(format: "Page %03d.pdf", i + 1)))
        }
        return folder
    }

    static func rotatePDF(_ url: URL) async throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConvertError("Couldn't open the PDF.") }
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
        let out = sibling(url, "rotated")
        guard doc.write(to: out) else { throw ConvertError("Couldn't write the PDF.") }
        return out
    }

    static func mergePDFs(_ urls: [URL]) async throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            guard let doc = PDFDocument(url: url) else { throw ConvertError("Couldn't open \(url.lastPathComponent).") }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = Converter.uniqueURL(in: urls[0].deletingLastPathComponent(), base: "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConvertError("Couldn't write the PDF.") }
        return out
    }

    // MARK: Metadata

    static func readMetadata(_ url: URL) async -> [MetaRow] {
        var rows: [MetaRow] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        rows.append(MetaRow(key: "File › Size", value: bytes(Int64(values?.fileSize ?? 0))))
        if let d = values?.creationDate { rows.append(MetaRow(key: "File › Created", value: d.formatted())) }
        if let d = values?.contentModificationDate { rows.append(MetaRow(key: "File › Modified", value: d.formatted())) }

        func describe(_ v: Any) -> String {
            if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
            return "\(v)"
        }
        switch Kind.of(url) {
        case .image, .raw:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { break }
            func walk(_ dict: [String: Any], _ group: String) {
                for key in dict.keys.sorted() {
                    if let nested = dict[key] as? [String: Any] {
                        walk(nested, key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))
                    } else {
                        rows.append(MetaRow(key: "\(group) › \(key)", value: describe(dict[key]!)))
                    }
                }
            }
            walk(props, "Image")
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration) {
                rows.append(MetaRow(key: "Media › Duration", value: Duration.seconds(d.seconds).formatted(.time(pattern: .hourMinuteSecond))))
            }
            for track in (try? await asset.load(.tracks)) ?? [] {
                if track.mediaType == .video, let size = try? await track.load(.naturalSize) {
                    rows.append(MetaRow(key: "Video › Dimensions", value: "\(Int(size.width)) × \(Int(size.height))"))
                    if let fps = try? await track.load(.nominalFrameRate) { rows.append(MetaRow(key: "Video › Frame rate", value: String(format: "%.2f fps", fps))) }
                }
                if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                    rows.append(MetaRow(key: "\(track.mediaType == .video ? "Video" : "Audio") › Bitrate", value: "\(Int(rate / 1000)) kbps"))
                }
            }
            for item in (try? await asset.load(.metadata)) ?? [] {
                let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "Tag"
                var value = (try? await item.load(.stringValue)) ?? ""
                if value.isEmpty, let v = try? await item.load(.value) { value = "\(v)" }
                rows.append(MetaRow(key: "Tag › \(key)", value: value))
            }
        case .pdf:
            guard let doc = PDFDocument(url: url) else { break }
            rows.append(MetaRow(key: "PDF › Pages", value: "\(doc.pageCount)"))
            for (k, v) in doc.documentAttributes ?? [:] { rows.append(MetaRow(key: "PDF › \(k)", value: describe(v))) }
        default: break
        }
        return rows
    }

    /// Writes a copy without EXIF/GPS/IPTC/XMP (images losslessly where the format allows), tags or document info.
    static func stripMetadata(_ url: URL) async throws -> URL {
        let out = sibling(url, "clean")
        switch Kind.of(url) {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
            else { throw ConvertError("Couldn't read the image.") }
            // Replace all metadata with just the orientation, so the picture still displays upright.
            let meta = CGImageMetadataCreateMutable()
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            if let orientation = props?[kCGImagePropertyOrientation] {
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation, orientation as CFTypeRef)
            }
            let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false,
                                            kCGImageMetadataShouldExcludeXMP: true, kCGImageMetadataShouldExcludeGPS: true]
            if !CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) {
                // Formats without lossless rewrite: re-encode the pixels with no properties at all.
                try? FileManager.default.removeItem(at: out)
                try save(try loadUpright(url).0, to: out, quality: 0.95)
            }
        case .video, .audio:
            let e = url.pathExtension.lowercased()
            guard taggableExtensions.contains(e) else { throw ConvertError("Convert to MP4/MOV/M4A first, then strip.") }
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetPassthrough, to: out, stripMetadata: true)
        case .pdf:
            guard let doc = PDFDocument(url: url) else { throw ConvertError("Couldn't open the PDF.") }
            doc.documentAttributes = [:]
            guard doc.write(to: out) else { throw ConvertError("Couldn't write the PDF.") }
        case .raw:
            throw ConvertError("RAW files can't be rewritten; convert to DNG, TIFF or JPEG with metadata stripped.")
        default:
            throw ConvertError("No metadata to strip here.")
        }
        return out
    }
}

struct MetaRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

// MARK: - Editor windows

@MainActor
enum Windows {
    private static var open: [NSWindow] = []

    @discardableResult
    static func show<V: View>(_ title: String, size: NSSize, _ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

@MainActor
enum Editors {
    static func open(_ op: Op, _ url: URL) {
        let name = url.lastPathComponent
        switch op {
        case .crop:
            let model = CropModel(url: url)
            model.window = Windows.show("Crop — \(name)", size: NSSize(width: 920, height: 680), CropView(model: model))
        case .trim, .snapshot:
            let model = MediaModel(url: url)
            Windows.show(name, size: NSSize(width: 860, height: model.isVideo ? 560 : 220), MediaView(model: model))
            if op == .trim { Task { await model.trim() } }
        case .metadata:
            Windows.show("Metadata — \(name)", size: NSSize(width: 700, height: 640), MetadataView(url: url))
        case .adjust:
            let model = AdjustModel(url: url)
            model.window = Windows.show("Adjust — \(name)", size: NSSize(width: 1000, height: 680), AdjustView(model: model))
        case .markup:
            let model = MarkupModel(url: url)
            model.window = Windows.show("Markup — \(name)", size: NSSize(width: 1000, height: 720), MarkupView(model: model))
        case .organize:
            let model = OrganizeModel(url: url)
            model.window = Windows.show("Organize — \(name)", size: NSSize(width: 860, height: 640), OrganizeView(model: model))
        case .info:
            openInfo([url])
        case .rename:
            Renamer.renameOne(url)
        case .batchRename:
            openBatchRename([url])
        case .translate:
            openInElingo([url])
        default: break
        }
    }

    /// Translate (and fill in and sign) lives in its own free app, Elingo. Hand the PDFs over in one go,
    /// so they share one window with a file list, or offer the app.
    static func openInElingo(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.itzkin.elingo") {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Translate opens in Elingo"
        alert.informativeText = "Elingo is a free companion app: fill in and sign a PDF in any language while a mirrored copy shows it translated into yours. It needs macOS 26 or later."
        alert.addButton(withTitle: "Get Elingo")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://ai.itzkin.com/elingo.html")!) }
    }

    static func openBatchRename(_ urls: [URL]) {
        let model = BatchRenameModel(urls: urls)
        model.window = Windows.show("Batch Rename — \(urls.count) files", size: NSSize(width: 720, height: 560), BatchRenameView(model: model))
    }

    static func openInfo(_ urls: [URL]) {
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        Windows.show("Size & Info — \(title)", size: NSSize(width: 560, height: 520), InfoView(model: InfoModel(urls: urls)))
    }
}

// MARK: Crop

/// Editor canvases show the picture fitted inside the view, and map pointer positions back onto it.
extension CGRect {
    static func fitting(_ image: CGImage, in size: CGSize, margin: CGFloat = 20) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = min((size.width - 2 * margin) / iw, (size.height - 2 * margin) / ih)
        return CGRect(x: (size.width - iw * scale) / 2, y: (size.height - ih * scale) / 2, width: iw * scale, height: ih * scale)
    }

    /// A point in the view as a 0…1 position on this rect (top-left origin), clamped to it.
    func normalised(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Swift.min(Swift.max((p.x - minX) / width, 0), 1), y: Swift.min(Swift.max((p.y - minY) / height, 0), 1))
    }
}

@MainActor
final class CropModel: ObservableObject {
    let url: URL
    @Published var image: CGImage?
    @Published var rect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)   // normalised, top-left origin
    @Published var aspect: CGFloat?
    @Published var error: String?
    @Published var saving = false
    let isVideo: Bool
    private var props: [CFString: Any] = [:]
    var dragStart: CGRect?
    weak var window: NSWindow?

    init(url: URL) {
        self.url = url
        isVideo = Kind.of(url) == .video
        if isVideo {
            Task { await loadFrame() }
        } else {
            do { (image, props) = try Ops.loadUpright(url) } catch { self.error = error.localizedDescription }
        }
    }

    /// For video, crop against a frame from a second in (or the middle of a short clip).
    private func loadFrame() async {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        do { image = try await generator.image(at: CMTime(seconds: min(1, seconds / 2), preferredTimescale: 600)).image }
        catch { self.error = "Couldn't read this video." }
    }

    var pixelRect: CGRect {
        guard let image else { return .zero }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
    }

    func setAspect(_ ratio: CGFloat?) {
        aspect = ratio
        guard let ratio, let image else { return }
        let imageRatio = CGFloat(image.width) / CGFloat(image.height)
        var size = ratio > imageRatio ? CGSize(width: 1, height: imageRatio / ratio) : CGSize(width: ratio / imageRatio, height: 1)
        size = CGSize(width: size.width * 0.9, height: size.height * 0.9)
        rect = CGRect(x: (1 - size.width) / 2, y: (1 - size.height) / 2, width: size.width, height: size.height)
    }

    func save() {
        if isVideo { Task { await saveVideo() }; return }
        guard let image, let cropped = image.cropping(to: pixelRect) else { return }
        do {
            let out = Ops.editedURL(url, "cropped")
            try Ops.save(cropped, to: out, props: Ops.keptMetadata(props))
            Ops.delivered([out], closing: window)
        } catch { self.error = error.localizedDescription }
    }

    private func saveVideo() async {
        saving = true
        defer { saving = false }
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConvertError("No video track.") }
            let transform = try await track.load(.preferredTransform)
            let fps = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration)
            var r = pixelRect
            r.size = CGSize(width: floor(r.width / 2) * 2, height: floor(r.height / 2) * 2)   // encoders want even sizes

            // The frame we cropped on is already upright, so: orient the track, then shift the crop to the origin.
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY)), at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            instruction.layerInstructions = [layer]
            let composition = AVMutableVideoComposition()
            composition.renderSize = r.size
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30))
            composition.instructions = [instruction]

            let out = Ops.sibling(url, "cropped", ext: Ops.movieExtension(url, else: "mp4"))
            try await Ops.export(asset, preset: AVAssetExportPresetHighestQuality, to: out, videoComposition: composition)
            Ops.delivered([out], closing: window)
        } catch { self.error = error.localizedDescription }
    }
}

struct CropView: View {
    @ObservedObject var model: CropModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let image = model.image { canvas(image, in: geo.size) }
                else { Text(model.error ?? "Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Color.black.opacity(0.85))
            Divider()
            HStack(spacing: 8) {
                ForEach([("Free", nil), ("1:1", 1.0), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:5", 0.8)] as [(String, CGFloat?)], id: \.0) { label, ratio in
                    Button(label) { model.setAspect(ratio) }
                        .buttonStyle(.bordered)
                        .tint(model.aspect == ratio ? accent : nil)
                }
                Spacer()
                Text("\(Int(model.pixelRect.width)) × \(Int(model.pixelRect.height)) px").monospacedDigit().foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red).lineLimit(1) }
                Button("Cancel") { model.window?.close() }.keyboardShortcut(.cancelAction)
                if model.saving { ProgressView().controlSize(.small) }
                Button(model.isVideo ? "Save Cropped Video" : "Save Crop") { model.save() }
                    .buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction).disabled(model.saving)
            }
            .padding(12)
        }
    }

    func canvas(_ image: CGImage, in size: CGSize) -> some View {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let fit = CGRect.fitting(image, in: size)
        let r = CGRect(x: fit.minX + model.rect.minX * fit.width, y: fit.minY + model.rect.minY * fit.height,
                       width: model.rect.width * fit.width, height: model.rect.height * fit.height)
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable()
                .frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
            Path { p in p.addRect(fit); p.addRect(r) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            // Rule-of-thirds guides.
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.35), lineWidth: 1)
            Rectangle().strokeBorder(Color.white, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                .gesture(DragGesture(coordinateSpace: .named("crop")).onChanged { v in
                    let start = model.dragStart ?? model.rect
                    model.dragStart = start
                    var moved = start.offsetBy(dx: v.translation.width / fit.width, dy: v.translation.height / fit.height)
                    moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                    moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                    model.rect = moved
                }.onEnded { _ in model.dragStart = nil })
                .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }
            ForEach(0..<4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                Circle().fill(Color.white).frame(width: 16, height: 16).shadow(radius: 2)
                    .position(point)
                    .gesture(DragGesture(coordinateSpace: .named("crop")).onChanged { v in
                        drag(corner: corner, to: fit.normalised(v.location), imageRatio: iw / ih)
                    })
            }
        }
        .coordinateSpace(name: "crop")
    }

    /// Moves one corner (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right), keeping the opposite one fixed.
    func drag(corner: Int, to p: CGPoint, imageRatio: CGFloat) {
        let r = model.rect
        var left = corner % 2 == 0 ? p.x : r.minX, right = corner % 2 == 1 ? p.x : r.maxX
        var top = corner < 2 ? p.y : r.minY, bottom = corner >= 2 ? p.y : r.maxY
        if right - left < 0.03 { if corner % 2 == 0 { left = right - 0.03 } else { right = left + 0.03 } }
        if bottom - top < 0.03 { if corner < 2 { top = bottom - 0.03 } else { bottom = top + 0.03 } }
        if let aspect = model.aspect {
            let height = (right - left) * imageRatio / aspect
            if corner < 2 { top = bottom - height } else { bottom = top + height }
            guard top >= 0, bottom <= 1 else { return }
        }
        model.rect = CGRect(x: max(left, 0), y: max(top, 0), width: min(right, 1) - max(left, 0), height: min(bottom, 1) - max(top, 0))
    }
}

// MARK: Trim / snapshot / split

@MainActor
final class MediaModel: ObservableObject {
    let url: URL
    let isVideo: Bool
    let player: AVPlayer
    let playerView = AVPlayerView()
    @Published var status: String?
    @Published var saved: [URL] = []
    @Published var busy = false

    init(url: URL) {
        self.url = url
        isVideo = Kind.of(url) == .video
        player = AVPlayer(url: url)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true
    }

    private func waitUntilReady() async {
        for _ in 0..<100 where player.currentItem?.status != .readyToPlay {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func trim() async {
        await waitUntilReady()
        guard playerView.canBeginTrimming else { status = "This file can't be trimmed."; return }
        let result = await withCheckedContinuation { cont in playerView.beginTrimming { cont.resume(returning: $0) } }
        guard result == .okButton, let item = player.currentItem else { return }
        let duration = item.duration
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
        await save { [try await self.exportRange(CMTimeRange(start: start, end: end), suffix: "trimmed")] }
    }

    func snapshot() async {
        let time = player.currentTime()
        await save {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: self.url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let (frame, _) = try await generator.image(at: time)
            let stamp = Duration.seconds(time.seconds).formatted(.time(pattern: .minuteSecond)).replacingOccurrences(of: ":", with: "-")
            let out = Ops.sibling(self.url, "snapshot \(stamp)", ext: "png")
            try Ops.save(frame, to: out)
            return [out]
        }
    }

    func split() async {
        guard let item = player.currentItem else { return }
        let t = player.currentTime(), duration = item.duration
        guard t.seconds > 0.1, t.seconds < duration.seconds - 0.1 else { status = "Move the playhead to where you want the cut."; return }
        await save {
            [try await self.exportRange(CMTimeRange(start: .zero, end: t), suffix: "part 1"),
             try await self.exportRange(CMTimeRange(start: t, end: duration), suffix: "part 2")]
        }
    }

    private func save(_ work: @escaping () async throws -> [URL]) async {
        busy = true
        status = "Saving…"
        defer { busy = false }
        do {
            saved = try await work()
            status = "Saved \(saved.map(\.lastPathComponent).joined(separator: ", "))"
        } catch { status = error.localizedDescription }
    }


    func exportRange(_ range: CMTimeRange, suffix: String) async throws -> URL {
        let e = url.pathExtension.lowercased()
        let ext = isVideo ? Ops.movieExtension(url, else: "mov") : "m4a"
        let preset = isVideo || e == "m4a" ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
        let out = Ops.sibling(url, suffix, ext: ext)
        try await Ops.export(AVURLAsset(url: url), preset: preset, to: out, timeRange: range)
        return out
    }
}

struct PlayerHost: NSViewRepresentable {
    let view: AVPlayerView
    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct MediaView: View {
    @ObservedObject var model: MediaModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerHost(view: model.playerView)
                .frame(minWidth: 640, minHeight: model.isVideo ? 380 : 80)
            Divider()
            HStack(spacing: 10) {
                Button { Task { await model.trim() } } label: { Label("Trim…", systemImage: "timeline.selection") }
                if model.isVideo {
                    Button { Task { await model.snapshot() } } label: { Label("Snapshot", systemImage: "camera") }
                }
                Button { Task { await model.split() } } label: { Label("Split at Playhead", systemImage: "scissors") }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if let status = model.status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if !model.saved.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.saved) }
                }
            }
            .disabled(model.busy)
            .padding(12)
        }
    }
}

// MARK: Metadata

@MainActor
final class MetadataModel: ObservableObject {
    @Published var rows: [MetaRow] = []
    @Published var loading = true
    @Published var status: String?
    @Published var saved: URL?
    @Published var edit = EditableMeta()
    private var original = EditableMeta()

    var editable: Bool { edit != original }

    func load(_ url: URL) async {
        rows = await Ops.readMetadata(url)
        original = await Ops.readEditable(url)
        edit = original
        loading = false
    }

    func saveEdits(_ url: URL) async {
        do {
            try await Ops.writeEditable(url, edit)
            status = "Saved changes"
            await load(url)
        } catch { status = error.localizedDescription }
    }

    func strip(_ url: URL) async {
        do {
            let out = try await Ops.stripMetadata(url)
            saved = out
            status = "Saved \(out.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }
}

struct MetadataView: View {
    let url: URL
    let kind: Kind   // looked up once; the form below is re-evaluated on every keystroke
    @StateObject private var model = MetadataModel()

    init(url: URL) {
        self.url = url
        kind = Kind.of(url)
    }

    var hasLocation: Bool { model.rows.contains { $0.key.hasPrefix("GPS") } }

    var body: some View {
        VStack(spacing: 0) {
            if hasLocation {
                Label("This file contains GPS location data.", systemImage: "location.fill")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(accent.opacity(0.18))
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.key).foregroundStyle(row.key.hasPrefix("GPS") ? accent : .secondary).frame(width: 240, alignment: .leading)
                        Text(row.value).textSelection(.enabled).lineLimit(3)
                    }
                    .font(.system(size: 12))
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            if [.image, .video, .audio, .pdf].contains(kind) {
                Form {
                    TextField("Title", text: $model.edit.title)
                    TextField(kind == .audio ? "Artist" : "Author", text: $model.edit.author)
                    if kind != .pdf { TextField("Copyright", text: $model.edit.copyright) }
                    TextField("Description", text: $model.edit.description)
                    if [.image, .pdf].contains(kind) { TextField("Keywords", text: $model.edit.keywords, prompt: Text("comma, separated")) }
                }
                .padding(.horizontal, 16).padding(.top, 10)
            }
            HStack {
                Text("\(model.rows.count) fields").foregroundStyle(.secondary)
                if let status = model.status { Text(status).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button("Remove All Metadata…") { Task { await model.strip(url) } }
                    .help("Saves a clean copy beside the original")
                Button("Save Changes") { Task { await model.saveEdits(url) } }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(!model.editable)
            }
            .padding(12)
        }
        .task { await model.load(url) }
    }
}
