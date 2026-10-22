// The bigger editor windows: size & info, adjust, markup, PDF organiser, metadata editing,
// plus 3D model conversion.

import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import Vision
import CoreImage
import ModelIO
import SceneKit
import SceneKit.ModelIO
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Size & Info

struct SizeItem: Identifiable {
    let id = UUID()
    let url: URL
    let isFolder: Bool
    var bytes: Int64 = 0
    var onDisk: Int64 = 0
    var files = 0
    var folders = 0

    /// Walks folders (packages included, as Finder counts them). Runs off the main thread.
    static func measure(_ url: URL) -> SizeItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        var item = SizeItem(url: url, isFolder: values?.isDirectory == true)
        guard item.isFolder else {
            item.bytes = Int64(values?.fileSize ?? 0)
            item.onDisk = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            item.files = 1
            return item
        }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = walker?.nextObject() as? URL {
            guard let v = try? f.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true { item.folders += 1; continue }
            item.files += 1
            item.bytes += Int64(v.fileSize ?? 0)
            item.onDisk += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        return item
    }
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

enum Checksums {
    private static let crcTable: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    }

    /// MD5, SHA-1, SHA-256, SHA-512 and CRC-32 in one streaming pass over the file.
    static func compute(_ url: URL) -> [(name: String, value: String)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        var crc: UInt32 = 0xFFFF_FFFF
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk); sha1.update(data: chunk); sha256.update(data: chunk); sha512.update(data: chunk)
            for byte in chunk { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        return [("MD5", hex(md5.finalize())), ("SHA-1", hex(sha1.finalize())), ("SHA-256", hex(sha256.finalize())),
                ("SHA-512", hex(sha512.finalize())), ("CRC-32", String(format: "%08x", ~crc))]
    }
}

@MainActor
final class InfoModel: ObservableObject {
    @Published var items: [SizeItem] = []
    @Published var pending: Int

    init(urls: [URL]) {
        pending = urls.count
        for url in urls {
            Task.detached(priority: .userInitiated) {
                let item = SizeItem.measure(url)
                await MainActor.run {
                    self.items.append(item)
                    self.items.sort { $0.bytes > $1.bytes }
                    self.pending -= 1
                }
            }
        }
    }

    @Published var hashes: [UUID: [(name: String, value: String)]] = [:]
    @Published var hashing = false
    @Published var expected = ""

    func computeChecksums() {
        hashing = true
        let files = items.filter { !$0.isFolder }
        Task.detached(priority: .userInitiated) {
            for item in files {
                let result = Checksums.compute(item.url)
                await MainActor.run { self.hashes[item.id] = result }
            }
            await MainActor.run { self.hashing = false }
        }
    }

    /// Which file and algorithm a pasted checksum matches, if any.
    var verification: String? {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty, !hashes.isEmpty else { return nil }
        for item in items {
            if let match = hashes[item.id]?.first(where: { $0.value == wanted }) {
                return "✓ Matches the \(match.name) of \(item.url.lastPathComponent)"
            }
        }
        return "✗ Doesn't match any checksum here"
    }

    var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var totalOnDisk: Int64 { items.reduce(0) { $0 + $1.onDisk } }
    var files: Int { items.reduce(0) { $0 + $1.files } }
    var folders: Int { items.reduce(0) { $0 + $1.folders + ($1.isFolder ? 1 : 0) } }

    var summary: String {
        "\(bytes(total)) (\(bytes(totalOnDisk)) on disk) · \(files.formatted()) files · \(folders.formatted()) folders"
    }
}

struct InfoView: View {
    @ObservedObject var model: InfoModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(model.total)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                    if model.pending > 0 { ProgressView().controlSize(.small).padding(.leading, 6) }
                }
                Text("\(bytes(model.totalOnDisk)) on disk · \(model.files.formatted()) files · \(model.folders.formatted()) folders · \(model.items.count) selected")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            List(model.items) { item in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        GeometryReader { geo in
                            Capsule().fill(accent.opacity(0.8))
                                .frame(width: max(3, geo.size.width * CGFloat(item.bytes) / CGFloat(max(model.total, 1))))
                        }.frame(height: 5)
                        if let hashes = model.hashes[item.id] {
                            ForEach(hashes, id: \.name) { h in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(h.name).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                                    Text(h.value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.value, forType: .string) }
                                        label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                            }
                        }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(bytes(item.bytes)).monospacedDigit().fontWeight(.semibold)
                        if item.isFolder { Text("\(item.files.formatted()) files").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 2)
                .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            HStack {
                if model.hashes.isEmpty {
                    Button(model.hashing ? "Computing…" : "Compute Checksums") { model.computeChecksums() }
                        .disabled(model.hashing || model.pending > 0 || model.items.allSatisfy(\.isFolder))
                } else {
                    TextField("Paste a checksum to verify", text: $model.expected).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    if let v = model.verification { Text(v).font(.callout).foregroundStyle(v.hasPrefix("✓") ? .green : .red).lineLimit(1) }
                }
                Spacer()
                Button("Copy Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.summary, forType: .string)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Adjust

@MainActor
final class AdjustModel: ObservableObject {
    let url: URL
    private var full: CGImage?
    private var props: [CFString: Any] = [:]
    private var previewBase: CIImage?
    private let context = CIContext()
    weak var window: NSWindow?

    @Published var preview: CGImage?
    @Published var error: String?
    @Published var exposure = 0.0 { didSet { render() } }
    @Published var contrast = 1.0 { didSet { render() } }
    @Published var saturation = 1.0 { didSet { render() } }
    @Published var warmth = 0.0 { didSet { render() } }
    @Published var highlights = 1.0 { didSet { render() } }
    @Published var shadows = 0.0 { didSet { render() } }
    @Published var sharpness = 0.0 { didSet { render() } }
    @Published var vignette = 0.0 { didSet { render() } }
    @Published var turns = 0 { didSet { render() } }
    @Published var mirrored = false { didSet { render() } }

    init(url: URL) {
        self.url = url
        do {
            (full, props) = try Ops.loadUpright(url)
            previewBase = CIImage(cgImage: Converter.resized(full!, maxSide: 1600))
            render()
        } catch { self.error = error.localizedDescription }
    }

    func reset() {
        (exposure, contrast, saturation, warmth, highlights, shadows, sharpness, vignette) = (0, 1, 1, 0, 1, 0, 0, 0)
        (turns, mirrored) = (0, false)
    }

    func apply(_ input: CIImage) -> CIImage {
        var img = input
        if mirrored { img = img.oriented(.upMirrored) }
        for _ in 0..<(turns % 4) { img = img.oriented(.right) }
        let extent = img.extent
        img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
        if warmth != 0 {
            // Telling Core Image the picture was shot under cooler light warms it, and vice versa.
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + warmth * 2500, y: 0)])
        }
        if highlights != 1 || shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": highlights, "inputShadowAmount": shadows])
        }
        if sharpness > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness]) }
        if vignette > 0 { img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: vignette * 2, kCIInputRadiusKey: 1.5]) }
        return img.cropped(to: extent)
    }

    func render() {
        guard let previewBase else { return }
        let out = apply(previewBase)
        preview = context.createCGImage(out, from: out.extent)
    }

    func save() {
        guard let full else { return }
        let out = apply(CIImage(cgImage: full))
        guard let cg = context.createCGImage(out, from: out.extent) else { return }
        do {
            let target = Ops.editedURL(url, "adjusted")
            try Ops.save(cg, to: target, props: Ops.keptMetadata(props))
            Donation.recordUse()
            NSWorkspace.shared.activateFileViewerSelecting([target])
            window?.close()
        } catch { self.error = error.localizedDescription }
    }
}

struct AdjustView: View {
    @ObservedObject var model: AdjustModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.85)
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(20)
                } else {
                    Text(model.error ?? "Loading…").foregroundStyle(.white)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                slider("Exposure", $model.exposure, -2...2)
                slider("Contrast", $model.contrast, 0.5...1.5)
                slider("Saturation", $model.saturation, 0...2)
                slider("Warmth", $model.warmth, -1...1)
                slider("Highlights", $model.highlights, 0...1)
                slider("Shadows", $model.shadows, 0...1)
                slider("Sharpness", $model.sharpness, 0...2)
                slider("Vignette", $model.vignette, 0...1)
                HStack {
                    Button { model.turns -= 1; if model.turns < 0 { model.turns += 4 } } label: { Image(systemName: "rotate.left") }
                    Button { model.turns += 1 } label: { Image(systemName: "rotate.right") }
                    Button { model.mirrored.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button("B&W") { model.saturation = 0 }
                    Spacer()
                    Button("Reset") { model.reset() }
                }
                Spacer()
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { model.window?.close() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save Copy") { model.save() }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 270)
        }
    }

    func slider(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.callout)
            Slider(value: value, in: range).tint(accent)
        }
    }
}

// MARK: - Markup (draw, arrows, boxes, text, blur, redact)

enum MarkTool: String, CaseIterable, Identifiable {
    case pen, arrow, box, text, blur, redact
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pen: "scribble"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .text: "textformat"
        case .blur: "aqi.medium"
        case .redact: "rectangle.fill"
        }
    }
    var help: String {
        switch self {
        case .pen: "Draw"
        case .arrow: "Arrow"
        case .box: "Box"
        case .text: "Text (type it below, then click the picture)"
        case .blur: "Pixelate an area"
        case .redact: "Black out an area"
        }
    }
}

struct Mark: Identifiable {
    let id = UUID()
    var tool: MarkTool
    var points: [CGPoint]   // normalised to the image, top-left origin
    var color: Color
    var width: CGFloat      // fraction of the image's width
    var text = ""
}

@MainActor
final class MarkupModel: ObservableObject {
    let url: URL
    @Published var image: CGImage?
    @Published var marks: [Mark] = []
    @Published var tool: MarkTool = .arrow
    @Published var color: Color = .red
    @Published var thickness: CGFloat = 0.006
    @Published var text = "Text"
    @Published var error: String?
    weak var window: NSWindow?

    init(url: URL) {
        self.url = url
        do { image = try Ops.loadUpright(url).0 } catch { self.error = error.localizedDescription }
    }

    var aspect: CGFloat { image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1 }

    /// Adds black boxes over every face, line of text and barcode Vision finds.
    func autoRedact() {
        guard let image else { return }
        let text = VNRecognizeTextRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let codes = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, faces, codes])
        let boxes = (text.results ?? []).map(\.boundingBox) + (faces.results ?? []).map(\.boundingBox) + (codes.results ?? []).map(\.boundingBox)
        if boxes.isEmpty { error = "Found no text, faces or codes."; return }
        for b in boxes {
            let pad = b.height * 0.15
            marks.append(Mark(tool: .redact, points: [CGPoint(x: b.minX - pad, y: 1 - b.maxY - pad), CGPoint(x: b.maxX + pad, y: 1 - b.minY + pad)],
                              color: .black, width: 0))
        }
    }

    func save() {
        guard let image else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Pixelated areas: draw a mosaic copy of the picture clipped to each box (bottom-left coordinates here).
        let blurs = marks.filter { $0.tool == .blur }
        if !blurs.isEmpty {
            let ci = CIImage(cgImage: image).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, w / 60)]).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            if let mosaic = CIContext().createCGImage(ci, from: ci.extent) {
                for m in blurs {
                    let r = rect(m, w, h)
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height))
                    ctx.draw(mosaic, in: CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.restoreGState()
                }
            }
        }

        // Everything else is drawn top-left-origin to match the normalised points.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for m in marks where m.tool != .blur {
            let color = NSColor(m.color).cgColor
            let lw = m.width * w
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let pts = m.points.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            switch m.tool {
            case .pen:
                guard let first = pts.first else { continue }
                ctx.move(to: first)
                pts.dropFirst().forEach { ctx.addLine(to: $0) }
                ctx.strokePath()
            case .arrow:
                guard pts.count == 2 else { continue }
                ctx.addPath(MarkupView.arrowPath(from: pts[0], to: pts[1], width: lw))
                ctx.strokePath()
            case .box:
                ctx.stroke(rect(m, w, h))
            case .redact:
                ctx.setFillColor(.black)
                ctx.fill(rect(m, w, h))
            case .text:
                guard let p = pts.first else { continue }
                NSAttributedString(string: m.text, attributes: [.font: NSFont.boldSystemFont(ofSize: w * 0.04),
                                                               .foregroundColor: NSColor(m.color)]).draw(at: p)
            case .blur: break
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let result = ctx.makeImage() else { return }
        do {
            let out = Ops.editedURL(url, "markup")
            try Ops.save(result, to: out)
            Donation.recordUse()
            NSWorkspace.shared.activateFileViewerSelecting([out])
            window?.close()
        } catch { self.error = error.localizedDescription }
    }

    private func rect(_ m: Mark, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        let a = m.points.first ?? .zero, b = m.points.last ?? .zero
        return CGRect(x: min(a.x, b.x) * w, y: min(a.y, b.y) * h, width: abs(b.x - a.x) * w, height: abs(b.y - a.y) * h)
    }
}

struct MarkupView: View {
    @ObservedObject var model: MarkupModel
    @StateObject private var drawing = MarkDraft()

    final class MarkDraft: ObservableObject { @Published var mark: Mark? }

    static func arrowPath(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(width * 4, 12)
        for side in [-1.0, 1.0] {
            let t = angle + .pi + side * 0.45
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x + head * cos(t), y: b.y + head * sin(t)))
        }
        return path
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                if let image = model.image { canvas(image, size: geo.size) }
                else { Text(model.error ?? "Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Color.black.opacity(0.85))
            Divider()
            HStack {
                Button("Auto-Redact Text & Faces") { model.autoRedact() }
                Button("Undo") { _ = model.marks.popLast() }.keyboardShortcut("z").disabled(model.marks.isEmpty)
                Button("Clear") { model.marks.removeAll() }.disabled(model.marks.isEmpty)
                if let error = model.error { Text(error).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("Cancel") { model.window?.close() }.keyboardShortcut(.cancelAction)
                Button("Save Copy") { model.save() }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(MarkTool.allCases) { tool in
                Button { model.tool = tool } label: { Image(systemName: tool.symbol).frame(width: 22) }
                    .buttonStyle(.bordered)
                    .tint(model.tool == tool ? accent : nil)
                    .help(tool.help)
            }
            Divider().frame(height: 20)
            ForEach([Color.red, .orange, .yellow, .green, .blue, .white, .black], id: \.self) { c in
                Circle().fill(c).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(model.color == c ? Color.primary : .gray.opacity(0.4), lineWidth: model.color == c ? 2 : 1))
                    .onTapGesture { model.color = c }
            }
            Divider().frame(height: 20)
            Slider(value: $model.thickness, in: 0.002...0.02).frame(width: 90).help("Line thickness")
            if model.tool == .text {
                TextField("Text", text: $model.text).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Spacer()
        }
        .padding(10)
    }

    func canvas(_ image: CGImage, size: CGSize) -> some View {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = min((size.width - 40) / iw, (size.height - 40) / ih)
        let fit = CGRect(x: (size.width - iw * scale) / 2, y: (size.height - ih * scale) / 2, width: iw * scale, height: ih * scale)
        func norm(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max((p.x - fit.minX) / fit.width, 0), 1), y: min(max((p.y - fit.minY) / fit.height, 0), 1))
        }
        let all = model.marks + (drawing.mark.map { [$0] } ?? [])
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
            Canvas { ctx, _ in
                for m in all {
                    let pts = m.points.map { CGPoint(x: fit.minX + $0.x * fit.width, y: fit.minY + $0.y * fit.height) }
                    let lw = m.width * fit.width
                    let box: CGRect = {
                        guard let a = pts.first, let b = pts.last else { return .zero }
                        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    }()
                    switch m.tool {
                    case .pen:
                        var p = Path()
                        p.addLines(pts)
                        ctx.stroke(p, with: .color(m.color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                    case .arrow where pts.count == 2:
                        ctx.stroke(Path(MarkupView.arrowPath(from: pts[0], to: pts[1], width: lw)), with: .color(m.color),
                                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                    case .box:
                        ctx.stroke(Path(box), with: .color(m.color), lineWidth: lw)
                    case .redact:
                        ctx.fill(Path(box), with: .color(.black))
                    case .blur:
                        // The real mosaic is applied when saving; preview it as a frosted patch.
                        ctx.fill(Path(box), with: .color(.gray.opacity(0.75)))
                        ctx.draw(Text("Pixelated").font(.caption.bold()).foregroundColor(.white), at: CGPoint(x: box.midX, y: box.midY))
                    case .text:
                        if let p = pts.first {
                            ctx.draw(Text(m.text).font(.system(size: fit.width * 0.04, weight: .bold)).foregroundColor(m.color),
                                     at: p, anchor: .topLeading)
                        }
                    default: break
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let p = norm(v.location)
                if drawing.mark == nil {
                    drawing.mark = Mark(tool: model.tool, points: [norm(v.startLocation)], color: model.color,
                                        width: model.thickness, text: model.text)
                }
                switch model.tool {
                case .pen: drawing.mark?.points.append(p)
                case .text: drawing.mark?.points = [p]
                default: drawing.mark?.points = [norm(v.startLocation), p]
                }
            }.onEnded { _ in
                if var m = drawing.mark {
                    if m.points.count == 1 && m.tool != .text { m.points.append(m.points[0]) }
                    if m.tool != .text || !m.text.isEmpty { model.marks.append(m) }
                }
                drawing.mark = nil
            })
        }
    }
}

// MARK: - PDF organiser

@MainActor
final class OrganizeModel: ObservableObject {
    struct Page: Identifiable {
        let id = UUID()
        let page: PDFPage
        var thumb: NSImage
    }

    let url: URL
    @Published var pages: [Page] = []
    @Published var error: String?
    weak var window: NSWindow?

    init(url: URL) {
        self.url = url
        guard let doc = PDFDocument(url: url) else { error = "Couldn't open the PDF."; return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            pages.append(Page(page: page, thumb: page.thumbnail(of: NSSize(width: 240, height: 320), for: .mediaBox)))
        }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), pages.count - 1)
        pages.move(fromOffsets: [i], toOffset: j > i ? j + 1 : j)
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let i = pages.firstIndex(where: { $0.id == id }),
              let j = pages.firstIndex(where: { $0.id == target }) else { return }
        pages.move(fromOffsets: [i], toOffset: j > i ? j + 1 : j)
    }

    func rotate(_ id: UUID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].page.rotation += 90
        pages[i].thumb = pages[i].page.thumbnail(of: NSSize(width: 240, height: 320), for: .mediaBox)
    }

    func delete(_ id: UUID) { pages.removeAll { $0.id == id } }

    func save() {
        let doc = PDFDocument()
        for p in pages { doc.insert(p.page, at: doc.pageCount) }
        let out = Ops.sibling(url, "organized")
        guard doc.write(to: out) else { error = "Couldn't write the PDF."; return }
        Donation.recordUse()
        NSWorkspace.shared.activateFileViewerSelecting([out])
        window?.close()
    }
}

struct OrganizeView: View {
    @ObservedObject var model: OrganizeModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 6) {
                            Image(nsImage: page.thumb).resizable().scaledToFit().frame(height: 180)
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Button { model.move(page.id, by: -1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                                Button { model.rotate(page.id) } label: { Image(systemName: "rotate.right") }
                                Button { model.delete(page.id) } label: { Image(systemName: "trash") }
                                Button { model.move(page.id, by: 1) } label: { Image(systemName: "chevron.right") }.disabled(index == model.pages.count - 1)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                        .onDrag { NSItemProvider(object: page.id.uuidString as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            _ = providers.first?.loadObject(ofClass: NSString.self) { s, _ in
                                guard let s = s as? String, let id = UUID(uuidString: s) else { return }
                                DispatchQueue.main.async { model.move(id, before: page.id) }
                            }
                            return true
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("Drag pages to reorder · \(model.pages.count) pages").foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Spacer()
                Button("Cancel") { model.window?.close() }.keyboardShortcut(.cancelAction)
                Button("Save Copy") { model.save() }.buttonStyle(.borderedProminent).tint(accent)
                    .keyboardShortcut(.defaultAction).disabled(model.pages.isEmpty)
            }
            .padding(12)
        }
    }
}

// MARK: - Editable metadata

struct EditableMeta: Equatable {
    var title = "", author = "", copyright = "", description = "", keywords = ""
}

extension Ops {
    static func readEditable(_ url: URL) async -> EditableMeta {
        var m = EditableMeta()
        switch Kind.of(url) {
        case .image, .raw:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { break }
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            m.title = iptc[kCGImagePropertyIPTCObjectName] as? String ?? ""
            m.author = tiff[kCGImagePropertyTIFFArtist] as? String ?? (iptc[kCGImagePropertyIPTCByline] as? [String])?.first ?? ""
            m.copyright = tiff[kCGImagePropertyTIFFCopyright] as? String ?? iptc[kCGImagePropertyIPTCCopyrightNotice] as? String ?? ""
            m.description = tiff[kCGImagePropertyTIFFImageDescription] as? String ?? iptc[kCGImagePropertyIPTCCaptionAbstract] as? String ?? ""
            m.keywords = (iptc[kCGImagePropertyIPTCKeywords] as? [String])?.joined(separator: ", ") ?? ""
        case .video, .audio:
            let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
            func value(_ ids: [AVMetadataIdentifier]) async -> String {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: ids[0]) + ids.dropFirst().flatMap({ AVMetadataItem.metadataItems(from: items, filteredByIdentifier: $0) }) {
                    if let s = try? await item.load(.stringValue) { return s }
                }
                return ""
            }
            m.title = await value([.commonIdentifierTitle])
            m.author = await value([.commonIdentifierArtist, .commonIdentifierCreator, .commonIdentifierAuthor])
            m.copyright = await value([.commonIdentifierCopyrights])
            m.description = await value([.commonIdentifierDescription])
        case .pdf:
            let a = PDFDocument(url: url)?.documentAttributes ?? [:]
            m.title = a[PDFDocumentAttribute.titleAttribute] as? String ?? ""
            m.author = a[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            m.description = a[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
            m.keywords = (a[PDFDocumentAttribute.keywordsAttribute] as? [String])?.joined(separator: ", ") ?? a[PDFDocumentAttribute.keywordsAttribute] as? String ?? ""
        default: break
        }
        return m
    }

    /// Writes the fields into the file itself (images without re-encoding), via a temp copy that replaces it.
    static func writeEditable(_ url: URL, _ m: EditableMeta) async throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".elconvo-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? fm.removeItem(at: tmp) }
        let keywords = m.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        switch Kind.of(url) {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
                  let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { throw ConvertError("Couldn't read the image.") }
            let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            func set(_ dict: CFString, _ key: CFString, _ value: Any) {
                CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, value as CFTypeRef)
            }
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName, m.title)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, m.author)
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCByline, [m.author])
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, m.copyright)
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice, m.copyright)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, m.description)
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, m.description)
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, keywords)
            let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
            guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else {
                throw ConvertError("This image format can't take new metadata without re-encoding.")
            }
        case .video, .audio:
            guard ["mov", "mp4", "m4v", "m4a"].contains(url.pathExtension.lowercased()) else {
                throw ConvertError("Convert to MP4/MOV/M4A first to edit its tags.")
            }
            let asset = AVURLAsset(url: url)
            let edited: [AVMetadataIdentifier: String] = [.commonIdentifierTitle: m.title, .commonIdentifierArtist: m.author,
                                                          .commonIdentifierCopyrights: m.copyright, .commonIdentifierDescription: m.description]
            var items = ((try? await asset.load(.metadata)) ?? []).filter { item in
                guard let id = item.identifier else { return true }
                return !edited.keys.contains(id) && item.commonKey.map { ![.commonKeyTitle, .commonKeyArtist, .commonKeyCopyrights, .commonKeyDescription].contains($0) } ?? true
            }
            for (id, value) in edited where !value.isEmpty {
                let item = AVMutableMetadataItem()
                item.identifier = id
                item.value = value as NSString
                items.append(item)
            }
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: tmp, metadata: items)
        case .pdf:
            guard let doc = PDFDocument(url: url) else { throw ConvertError("Couldn't open the PDF.") }
            var attrs = doc.documentAttributes ?? [:]
            attrs[PDFDocumentAttribute.titleAttribute] = m.title
            attrs[PDFDocumentAttribute.authorAttribute] = m.author
            attrs[PDFDocumentAttribute.subjectAttribute] = m.description
            attrs[PDFDocumentAttribute.keywordsAttribute] = keywords
            doc.documentAttributes = attrs
            guard doc.write(to: tmp) else { throw ConvertError("Couldn't write the PDF.") }
        default:
            throw ConvertError("RAW and other files can't be edited in place; convert them first.")
        }
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }
}

// MARK: - 3D models

extension Kind {
    static let modelExtensions: Set<String> = ["obj", "stl", "ply", "3mf", "usdz", "usd", "usda", "usdc", "abc"]
}

enum Models3D {
    struct Triangle { var a, b, c: SIMD3<Float> }

    static let outputs: [Format] = [
        .init(id: "stl", ext: "stl", label: "STL"),
        .init(id: "3mf", ext: "3mf", label: "3MF"),
        .init(id: "obj", ext: "obj", label: "OBJ"),
        .init(id: "ply", ext: "ply", label: "PLY"),
        .init(id: "usdz", ext: "usdz", label: "USDZ"),
        .init(id: "usda", ext: "usda", label: "USDA"),
    ]

    static func convert(_ input: URL, to out: URL, formatID: String) throws {
        let tris = try load(input)
        guard !tris.isEmpty else { throw ConvertError("No triangles found in this model.") }
        switch formatID {
        case "stl": try writeSTL(tris, to: out)
        case "obj": try writeOBJ(tris, to: out)
        case "ply": try writePLY(tris, to: out)
        case "3mf": try write3MF(tris, to: out)
        default: try writeModelIO(tris, to: out)
        }
    }

    // MARK: Reading

    static func load(_ url: URL) throws -> [Triangle] {
        if url.pathExtension.lowercased() == "3mf" { return try read3MF(url) }
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else {
            throw ConvertError("macOS can't read .\(url.pathExtension) models.")
        }
        let asset = MDLAsset(url: url)
        var tris: [Triangle] = []
        func walk(_ object: MDLObject, _ parent: simd_float4x4) {
            let local = object.transform?.matrix ?? matrix_identity_float4x4
            let world = parent * local
            if let mesh = object as? MDLMesh { tris += triangles(of: mesh, world) }
            for child in object.children.objects { walk(child, world) }
        }
        for i in 0..<asset.count { walk(asset.object(at: i), matrix_identity_float4x4) }
        return tris
    }

    static func triangles(of mesh: MDLMesh, _ transform: simd_float4x4) -> [Triangle] {
        guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return [] }
        let base = positions.dataStart
        func vertex(_ i: Int) -> SIMD3<Float> {
            let p = base.advanced(by: i * positions.stride).assumingMemoryBound(to: Float.self)
            let v = transform * SIMD4<Float>(p[0], p[1], p[2], 1)
            return SIMD3(v.x, v.y, v.z)
        }
        var tris: [Triangle] = []
        for case let sub as MDLSubmesh in mesh.submeshes ?? [] where sub.geometryType == .triangles {
            let map = sub.indexBuffer.map()
            let count = sub.indexCount
            func index(_ i: Int) -> Int {
                switch sub.indexType {
                case .uInt8: return Int(map.bytes.assumingMemoryBound(to: UInt8.self)[i])
                case .uInt16: return Int(map.bytes.assumingMemoryBound(to: UInt16.self)[i])
                default: return Int(map.bytes.assumingMemoryBound(to: UInt32.self)[i])
                }
            }
            for t in stride(from: 0, to: count - 2, by: 3) {
                tris.append(Triangle(a: vertex(index(t)), b: vertex(index(t + 1)), c: vertex(index(t + 2))))
            }
        }
        return tris
    }

    /// 3MF is a zip of XML; this reads every mesh in every model part (geometry only, no colours).
    static func read3MF(_ url: URL) throws -> [Triangle] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("elconvo-3mf-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try Converter.runSync("/usr/bin/tar", ["-x", "-f", url.path, "-C", temp.path])
        var tris: [Triangle] = []
        let walker = fm.enumerator(at: temp, includingPropertiesForKeys: nil)
        while let f = walker?.nextObject() as? URL {
            guard f.pathExtension.lowercased() == "model" else { continue }
            let reader = ThreeMFReader()
            let parser = XMLParser(contentsOf: f)!
            parser.delegate = reader
            parser.parse()
            tris += reader.triangles
        }
        return tris
    }

    final class ThreeMFReader: NSObject, XMLParserDelegate {
        var vertices: [SIMD3<Float>] = []
        var triangles: [Triangle] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name.split(separator: ":").last {
            case "mesh": vertices = []
            case "vertex":
                vertices.append(SIMD3(Float(a["x"] ?? "") ?? 0, Float(a["y"] ?? "") ?? 0, Float(a["z"] ?? "") ?? 0))
            case "triangle":
                guard let i = Int(a["v1"] ?? ""), let j = Int(a["v2"] ?? ""), let k = Int(a["v3"] ?? ""),
                      max(i, j, k) < vertices.count else { return }
                triangles.append(Triangle(a: vertices[i], b: vertices[j], c: vertices[k]))
            default: break
            }
        }
    }

    // MARK: Writing

    /// Shared vertices and index triples, for the formats that want them.
    static func indexed(_ tris: [Triangle]) -> (vertices: [SIMD3<Float>], faces: [(Int, Int, Int)]) {
        var lookup: [SIMD3<Float>: Int] = [:]
        var vertices: [SIMD3<Float>] = []
        func id(_ v: SIMD3<Float>) -> Int {
            if let i = lookup[v] { return i }
            lookup[v] = vertices.count
            vertices.append(v)
            return vertices.count - 1
        }
        let faces = tris.map { (id($0.a), id($0.b), id($0.c)) }
        return (vertices, faces)
    }

    static func writeSTL(_ tris: [Triangle], to out: URL) throws {
        var data = Data(count: 80)   // header
        var count = UInt32(tris.count)
        data.append(Data(bytes: &count, count: 4))
        for t in tris {
            var floats = [simd_normalize(simd_cross(t.b - t.a, t.c - t.a))]
            floats += [t.a, t.b, t.c]
            for v in floats {
                var xyz = [v.x.isNaN ? 0 : v.x, v.y.isNaN ? 0 : v.y, v.z.isNaN ? 0 : v.z]
                data.append(Data(bytes: &xyz, count: 12))
            }
            data.append(contentsOf: [0, 0])   // attribute byte count
        }
        try data.write(to: out)
    }

    static func writeOBJ(_ tris: [Triangle], to out: URL) throws {
        let (vertices, faces) = indexed(tris)
        var s = "# Exported by Elconvo\n"
        s.reserveCapacity(vertices.count * 32 + faces.count * 24)
        for v in vertices { s += "v \(v.x) \(v.y) \(v.z)\n" }
        for f in faces { s += "f \(f.0 + 1) \(f.1 + 1) \(f.2 + 1)\n" }
        try s.write(to: out, atomically: true, encoding: .utf8)
    }

    static func writePLY(_ tris: [Triangle], to out: URL) throws {
        let (vertices, faces) = indexed(tris)
        var s = "ply\nformat ascii 1.0\ncomment Exported by Elconvo\nelement vertex \(vertices.count)\nproperty float x\nproperty float y\nproperty float z\nelement face \(faces.count)\nproperty list uchar int vertex_indices\nend_header\n"
        for v in vertices { s += "\(v.x) \(v.y) \(v.z)\n" }
        for f in faces { s += "3 \(f.0) \(f.1) \(f.2)\n" }
        try s.write(to: out, atomically: true, encoding: .utf8)
    }

    static func write3MF(_ tris: [Triangle], to out: URL) throws {
        let (vertices, faces) = indexed(tris)
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("elconvo-3mf-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("3D"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
        """.write(to: stage.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """.write(to: stage.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        var model = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n<resources><object id=\"1\" type=\"model\"><mesh><vertices>\n"
        for v in vertices { model += "<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>\n" }
        model += "</vertices><triangles>\n"
        for f in faces { model += "<triangle v1=\"\(f.0)\" v2=\"\(f.1)\" v3=\"\(f.2)\"/>\n" }
        model += "</triangles></mesh></object></resources>\n<build><item objectid=\"1\"/></build>\n</model>\n"
        try model.write(to: stage.appendingPathComponent("3D/3dmodel.model"), atomically: true, encoding: .utf8)
        try Converter.runSync("/usr/bin/tar", ["-c", "-f", out.path, "--format", "zip", "-C", stage.path,
                                               "[Content_Types].xml", "_rels", "3D"], env: ["COPYFILE_DISABLE": "1"])
    }

    /// USDA through Model I/O; USDZ through SceneKit, since Model I/O can't package it.
    static func writeModelIO(_ tris: [Triangle], to out: URL) throws {
        let (vertices, faces) = indexed(tris)
        var flat = vertices.flatMap { [$0.x, $0.y, $0.z] }
        var indices = faces.flatMap { [UInt32($0.0), UInt32($0.1), UInt32($0.2)] }
        let allocator = MDLMeshBufferDataAllocator()
        let vertexBuffer = allocator.newBuffer(with: Data(bytes: &flat, count: flat.count * 4), type: .vertex)
        let indexBuffer = allocator.newBuffer(with: Data(bytes: &indices, count: indices.count * 4), type: .index)
        let submesh = MDLSubmesh(indexBuffer: indexBuffer, indexCount: indices.count, indexType: .uInt32,
                                 geometryType: .triangles, material: MDLMaterial(name: "Default", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction()))
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        let mesh = MDLMesh(vertexBuffer: vertexBuffer, vertexCount: vertices.count, descriptor: descriptor, submeshes: [submesh])
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        let asset = MDLAsset()
        asset.add(mesh)
        if out.pathExtension.lowercased() == "usdz" {
            let scene = SCNScene(mdlAsset: asset)
            guard scene.write(to: out, options: nil, delegate: nil, progressHandler: nil) else {
                throw ConvertError("Couldn't write the USDZ.")
            }
        } else {
            guard MDLAsset.canExportFileExtension(out.pathExtension.lowercased()) else {
                throw ConvertError("This Mac can't write .\(out.pathExtension).")
            }
            try asset.export(to: out)
        }
    }
}
