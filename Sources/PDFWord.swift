// PDF → Word that keeps the document's structure: headings, paragraphs, lists and real tables.
//
// Vision's document recognition (macOS 26+) finds the layout on a rendered page. For PDFs with a
// text layer, the words, font sizes and bold come from the PDF itself so nothing is mis-read; scanned
// pages fall back to Vision's OCR. The .docx is written by hand (it's a zip of a few XML files).

import AppKit
import PDFKit
import Vision

@available(macOS 26.0, *)
enum PDFToWord {
    typealias Container = DocumentObservation.Container

    struct Run {
        var text: String
        var bold = false
        var size: CGFloat?        // points, when the PDF says
        var lineHeight: CGFloat   // points: average height of the text's lines on the page
        var marker: String?       // bullet or number, when the paragraph is really a list item
    }

    static let bullets: Set<Character> = ["•", "◦", "▪", "●", "■", "–", "-", "*", "‣", "○"]

    /// Splits a leading "• " or "3. " off the text.
    static func splitMarker(_ text: String) -> (String, String)? {
        if let first = text.first, bullets.contains(first), text.dropFirst().first?.isWhitespace == true {
            return (String(first), text.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        if let m = text.range(of: #"^(\d{1,3}|[a-zA-Z])[.)]\s+"#, options: .regularExpression) {
            return (text[m].trimmingCharacters(in: .whitespaces), String(text[m.upperBound...]))
        }
        return nil
    }

    static func convert(_ input: URL, to out: URL) async throws {
        guard let doc = PDFDocument(url: input), doc.pageCount > 0, let first = doc.page(at: 0) else {
            throw ConvertError("Couldn't open the PDF.")
        }
        var body = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            Converter.report?("page \(i + 1) of \(doc.pageCount)")
            if i > 0 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            do {
                body += try await pageXML(page)
            } catch is LayoutTimeout {
                body += plainPageXML(page)   // keep going with the words, minus the structure
            }
        }
        try write(body: body, pageSize: displaySize(first), to: out)
    }

    static func displaySize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    // MARK: One page

    static func pageXML(_ page: PDFPage) async throws -> String {
        let size = displaySize(page)
        guard let image = Converter.render(page, scale: 2400 / max(size.width, size.height), box: .cropBox) else { return "" }
        guard let container = try await recognize(image) else { return "" }

        let box = page.bounds(for: .cropBox)
        let textLayer = page.rotation == 0 && !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        /// Normalised (lower-left origin) → PDF page coordinates.
        func onPage(_ r: NormalizedRect) -> CGRect {
            CGRect(x: box.minX + r.origin.x * box.width, y: box.minY + r.origin.y * box.height,
                   width: r.width * box.width, height: r.height * box.height)
        }

        func run(_ text: Container.Text) -> Run {
            let bounds = text.boundingRegion.boundingBox
            let lines = max(text.lines.count, 1)
            // Per-line glyph height is comparable between one-line headings and long paragraphs;
            // a paragraph's whole box over its line count is not (it includes the leading).
            let glyph = text.lines.isEmpty ? bounds.height / CGFloat(lines)
                : text.lines.map(\.boundingBox.height).reduce(0, +) / CGFloat(text.lines.count)
            var result = Run(text: flow(text.transcript, text), lineHeight: glyph * size.height)
            guard textLayer else { return withMarker(result) }
            // Prefer the PDF's own characters when they clearly describe the same text.
            let area = onPage(bounds)
            guard let selection = page.selection(for: area.insetBy(dx: -2, dy: area.height / CGFloat(lines) * 0.2)),
                  let exact = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !exact.isEmpty else { return result }
            let ratio = Double(exact.count) / Double(max(result.text.count, 1))
            if ratio > 0.6 && ratio < 1.6 { result.text = flow(exact, text) }
            // A bullet glyph often sits just left of the box Vision drew around the text.
            if splitMarker(result.text) == nil,
               let wider = page.selection(for: CGRect(x: area.minX - 28, y: area.maxY - area.height / CGFloat(lines),
                                                      width: 30, height: area.height / CGFloat(lines)))?.string?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               let glyph = wider.first, bullets.contains(glyph), wider.count <= 3 {
                result.marker = String(glyph)
            }
            if let attributed = selection.attributedString, attributed.length > 0,
               let font = attributed.attribute(.font, at: attributed.length / 2, effectiveRange: nil) as? NSFont {
                result.size = font.pointSize
                let name = font.fontName.lowercased()
                result.bold = font.fontDescriptor.symbolicTraits.contains(.bold)
                    || ["bold", "black", "heavy", "semibold"].contains { name.contains($0) }
            }
            return withMarker(result)
        }

        func withMarker(_ run: Run) -> Run {
            var run = run
            if run.marker == nil, let (marker, rest) = splitMarker(run.text) { run.marker = marker; run.text = rest }
            return run
        }

        // Tables and lists own the text inside them; paragraphs that fall within them are skipped.
        let owned = container.tables.map { $0.boundingRegion.boundingBox.cgRect } + container.lists.map { $0.boundingRegion.boundingBox.cgRect }
        func isOwned(_ r: NormalizedRect) -> Bool {
            let mid = CGPoint(x: r.cgRect.midX, y: r.cgRect.midY)
            return owned.contains { $0.insetBy(dx: -0.005, dy: -0.005).contains(mid) }
        }

        let paragraphs = container.paragraphs.filter { !isOwned($0.boundingRegion.boundingBox) }
        let runs = paragraphs.map(run)
        // Compare like with like: real font sizes when the PDF has them, measured glyph heights otherwise.
        func measure(_ r: Run) -> CGFloat { textLayer ? (r.size ?? r.lineHeight) : r.lineHeight }
        let body = weightedMedian(runs.filter { $0.marker == nil }.map { (measure($0), $0.text.count) }) ?? 11

        // Short lines set clearly larger than the body are headings; the biggest ones are level 1.
        func isHeading(_ size: CGFloat, _ p: Container.Text) -> Bool { size >= body * 1.15 && p.lines.count <= 3 }
        let largestHeading = zip(paragraphs, runs).filter { $1.marker == nil && isHeading(measure($1), $0) }.map { measure($1) }.max() ?? 0

        var blocks: [(top: CGFloat, left: CGFloat, xml: String)] = []
        for (p, r) in zip(paragraphs, runs) {
            let b = p.boundingRegion.boundingBox.cgRect
            if let marker = r.marker {
                blocks.append((b.maxY, b.minX, paragraphXML(r.text, marker: marker)))
                continue
            }
            let estimated = measure(r)
            var style: String?
            if p == container.title { style = "Title" }
            else if isHeading(estimated, p) { style = estimated >= largestHeading * 0.92 ? "Heading1" : "Heading2" }
            let align = p.textAlignment == .center ? "center" : p.textAlignment == .trailing ? "right" : nil
            blocks.append((b.maxY, b.minX, paragraphXML(r.text, style: style, align: align, bold: r.bold && style == nil)))
        }
        for list in container.lists {
            for item in list.items {
                let b = item.content.text.boundingRegion.boundingBox.cgRect
                let r = run(item.content.text)
                let marker = item.markerString.trimmingCharacters(in: .whitespaces)
                blocks.append((b.maxY, b.minX, paragraphXML(r.text, marker: marker.isEmpty ? (r.marker ?? "•") : marker)))
            }
        }
        for table in container.tables {
            let b = table.boundingRegion.boundingBox.cgRect
            blocks.append((b.maxY, b.minX, tableXML(table, pageWidth: size.width, read: run)))
        }
        // Top of the page first (Vision's y grows upward), then left to right.
        blocks.sort { abs($0.top - $1.top) > 0.004 ? $0.top > $1.top : $0.left < $1.left }
        return blocks.map(\.xml).joined()
    }

    struct LayoutTimeout: Error {}

    /// Vision's layout model is loaded by a system service on first use, and that has been seen to stall
    /// for minutes. Give each page a fixed budget instead of waiting forever.
    static func recognize(_ image: CGImage, seconds: Double = 30) async throws -> Container? {
        // Not a task group: a group waits for every child, so a request that ignores cancellation
        // would still hold us. Whichever side finishes first resumes; the other is ignored.
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let work = Task {
                do {
                    let result = try await RecognizeDocumentsRequest().perform(on: image).first?.document
                    if once.claim() { continuation.resume(returning: result) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    work.cancel()
                    continuation.resume(throwing: LayoutTimeout())
                }
            }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
    }

    /// The page's text (or OCR of it) as plain paragraphs, for when layout recognition gives up.
    static func plainPageXML(_ page: PDFPage) -> String {
        var text = page.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = Converter.ocr(page) }
        return text.components(separatedBy: "\n\n").map { block in
            paragraphXML(block.trimmingCharacters(in: .whitespacesAndNewlines))
        }.joined()
    }

    /// Lets Word re-flow body text, but keeps the line breaks of short-lined blocks (addresses, signatures).
    static func flow(_ text: String, _ shape: Container.Text) -> String {
        let width = shape.boundingRegion.boundingBox.width
        let lines = shape.lines
        let ragged = lines.dropLast().contains { $0.boundingBox.width < width * 0.7 }
        let clean = text.replacingOccurrences(of: "\r", with: "\n")
        if ragged || lines.count <= 1 { return clean }
        return clean.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\n", with: " ")
    }

    /// The size most of the text is set in: a few big headings can't drag it up.
    static func weightedMedian(_ values: [(CGFloat, Int)]) -> CGFloat? {
        let sorted = values.sorted { $0.0 < $1.0 }
        let half = sorted.reduce(0) { $0 + $1.1 } / 2
        var seen = 0
        for (value, weight) in sorted {
            seen += weight
            if seen >= half { return value }
        }
        return sorted.last?.0
    }

    // MARK: XML

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: Converter.controlCharacters, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func runsXML(_ text: String, bold: Bool = false) -> String {
        let props = bold ? "<w:rPr><w:b/></w:rPr>" : ""
        let parts = text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }
        return "<w:r>\(props)\(parts.joined(separator: "<w:br/>"))</w:r>"
    }

    static func paragraphXML(_ text: String, style: String? = nil, align: String? = nil, bold: Bool = false, marker: String? = nil) -> String {
        var props = ""
        if let style { props += "<w:pStyle w:val=\"\(style)\"/>" }
        if marker != nil { props += "<w:tabs><w:tab w:val=\"left\" w:pos=\"720\"/></w:tabs><w:ind w:left=\"720\" w:hanging=\"360\"/>" }
        if let align { props += "<w:jc w:val=\"\(align)\"/>" }
        let lead = marker.map { "<w:r><w:t xml:space=\"preserve\">\(escape($0))</w:t><w:tab/></w:r>" } ?? ""
        return "<w:p><w:pPr>\(props)</w:pPr>\(lead)\(runsXML(text, bold: bold))</w:p>"
    }

    static func tableXML(_ table: Container.Table, pageWidth: CGFloat, read: (Container.Text) -> Run) -> String {
        // Every distinct cell once (spanning cells show up in several rows), then a grid of who covers what.
        var cells: [Container.Table.Cell] = []
        for row in table.rows { for cell in row where !cells.contains(cell) { cells.append(cell) } }
        guard !cells.isEmpty else { return "" }
        let rowCount = cells.map(\.rowRange.upperBound).max()! + 1
        let colCount = cells.map(\.columnRange.upperBound).max()! + 1
        var grid = [[Int?]](repeating: [Int?](repeating: nil, count: colCount), count: rowCount)
        for (i, cell) in cells.enumerated() {
            for r in cell.rowRange { for c in cell.columnRange { grid[r][c] = i } }
        }

        // Column widths from single-column cells; the table keeps its share of the page's text width.
        let tableBox = table.boundingRegion.boundingBox.cgRect
        let textWidth = Int(pageWidth * 20) - 2 * margin
        let tableWidth = Int(Double(textWidth) * min(1, tableBox.width / ((pageWidth - 2 * CGFloat(margin) / 20) / pageWidth)))
        var widths = [CGFloat](repeating: 0, count: colCount)
        for cell in cells where cell.columnRange.count == 1 {
            widths[cell.columnRange.lowerBound] = max(widths[cell.columnRange.lowerBound], cell.content.boundingRegion.boundingBox.width)
        }
        let known = widths.filter { $0 > 0 }
        let fallback = known.isEmpty ? 1 : known.reduce(0, +) / CGFloat(known.count)
        widths = widths.map { $0 > 0 ? $0 : fallback }
        let sum = widths.reduce(0, +)
        let twips = widths.map { max(400, Int(CGFloat(tableWidth) * $0 / sum)) }

        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(twips.reduce(0, +))\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/></w:tblPr><w:tblGrid>"
        xml += twips.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        for r in 0..<rowCount {
            xml += "<w:tr>"
            var c = 0
            while c < colCount {
                guard let index = grid[r][c] else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(twips[c])\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    c += 1
                    continue
                }
                let cell = cells[index]
                let span = cell.columnRange.count
                let width = twips[cell.columnRange].reduce(0, +)
                var props = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                if span > 1 { props += "<w:gridSpan w:val=\"\(span)\"/>" }
                let startsHere = cell.rowRange.lowerBound == r
                if cell.rowRange.count > 1 { props += startsHere ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
                var content = "<w:p/>"
                if startsHere {
                    let text = read(cell.content.text)
                    content = "<w:p>\(runsXML(text.text, bold: text.bold))</w:p>"
                }
                xml += "<w:tc><w:tcPr>\(props)</w:tcPr>\(content)</w:tc>"
                c = cell.columnRange.upperBound + 1
            }
            xml += "</w:tr>"
        }
        // Word needs a paragraph between back-to-back tables.
        return xml + "</w:tbl><w:p/>"
    }

    // MARK: Package

    static let margin = 1080   // ¾ inch, in twips

    static func write(body: String, pageSize: CGSize, to out: URL) throws {
        let w = Int(pageSize.width * 20), h = Int(pageSize.height * 20)
        try Converter.writeZip([
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """,
            "word/styles.xml": styles,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="\(w)" w:h="\(h)"\(w > h ? " w:orient=\"landscape\"" : "")/><w:pgMar w:top="\(margin)" w:right="\(margin)" w:bottom="\(margin)" w:left="\(margin)" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
            """,
        ], to: out)
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="34"/><w:szCs w:val="34"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="27"/><w:szCs w:val="27"/></w:rPr></w:style>
    <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:pPr><w:spacing w:after="0"/></w:pPr><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:left w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:right w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="808080"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="808080"/></w:tblBorders></w:tblPr></w:style>
    </w:styles>
    """
}
