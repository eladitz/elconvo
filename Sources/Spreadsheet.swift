// Spreadsheets: read Excel (.xlsx/.xlsm) and OpenDocument (.ods) directly — they're zips of XML — and
// old .xls / Apple .numbers through Numbers. Write CSV, TSV, JSON, an HTML table, PDF, or XLSX.

import AppKit

enum Spreadsheet {
    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    static let outputs: [Format] = [
        .init(id: "sheet-csv", ext: "csv", label: "CSV"),
        .init(id: "xlsx", ext: "xlsx", label: "Excel (XLSX)"),
        .init(id: "sheet-pdf", ext: "pdf", label: "PDF"),
        .init(id: "sheet-json", ext: "json", label: "JSON"),
        .init(id: "sheet-tsv", ext: "tsv", label: "TSV"),
        .init(id: "sheet-html", ext: "html", label: "HTML table"),
    ]

    // MARK: Converting

    /// A spreadsheet in, any of `outputs` out. Several sheets become a folder with one file per sheet
    /// (except XLSX and PDF, which hold them all).
    @MainActor
    static func convert(_ input: URL, to out: URL, formatID: String) async throws -> URL {
        let sheets = try await read(input).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw ConvertError("The spreadsheet is empty.") }
        return try write(sheets, to: out, formatID: formatID)
    }

    @MainActor
    static func write(_ sheets: [Sheet], to out: URL, formatID: String) throws -> URL {
        switch formatID {
        case "xlsx":
            try writeXLSX(sheets, to: out)
            return out
        case "sheet-pdf":
            try Converter.writePDF(attributed(html(sheets)), to: out)
            return out
        default:
            let ext = out.pathExtension
            func text(_ sheet: Sheet) -> String {
                switch formatID {
                case "sheet-tsv": return delimited(sheet.rows, "\t")
                case "sheet-json": return json(sheet.rows)
                case "sheet-html": return html([sheet])
                default: return delimited(sheet.rows, ",")
                }
            }
            if sheets.count == 1 {
                try text(sheets[0]).write(to: out, atomically: true, encoding: .utf8)
                return out
            }
            let folder = Converter.uniqueURL(in: out.deletingLastPathComponent(), base: out.deletingPathExtension().lastPathComponent, ext: "")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for sheet in sheets {
                let name = sheet.name.replacingOccurrences(of: "/", with: "-")
                try text(sheet).write(to: folder.appendingPathComponent(name).appendingPathExtension(ext), atomically: true, encoding: .utf8)
            }
            return folder
        }
    }

    // MARK: Reading

    static func read(_ url: URL) async throws -> [Sheet] {
        switch url.pathExtension.lowercased() {
        case "xlsx", "xlsm": return try readXLSX(url)
        case "ods": return try readODS(url)
        default:
            // .xls and .numbers: Numbers opens them and hands back an .xlsx we can read.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("elconvo-\(UUID().uuidString).xlsx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await viaNumbers(url, to: temp)
            return try readXLSX(temp)
        }
    }

    static var numbersInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Numbers") != nil }

    private static func viaNumbers(_ url: URL, to xlsx: URL) async throws {
        guard numbersInstalled else {
            throw ConvertError(".\(url.pathExtension) files need Apple's Numbers app (free in the App Store) to be read.")
        }
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = """
        tell application "Numbers"
            set d to open POSIX file \(quoted(url.path))
            export d to POSIX file \(quoted(xlsx.path)) as Microsoft Excel
            close d saving no
        end tell
        """
        try await Converter.run("/usr/bin/osascript", ["-e", script])
        guard FileManager.default.fileExists(atPath: xlsx.path) else { throw ConvertError("Numbers couldn't export this file.") }
    }

    private static func unzip(_ url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("elconvo-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Converter.runSync("/usr/bin/tar", ["-x", "-f", url.path, "-C", dir.path])
        return dir
    }

    private static func parse(_ file: URL, _ delegate: XMLParserDelegate) {
        guard let parser = XMLParser(contentsOf: file) else { return }
        parser.delegate = delegate
        parser.parse()
    }

    // XLSX: xl/workbook.xml lists the sheets, xl/_rels says which file each is, sharedStrings holds the text,
    // styles says which number formats are dates.
    static func readXLSX(_ url: URL) throws -> [Sheet] {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xl = dir.appendingPathComponent("xl")

        let workbook = WorkbookReader()
        parse(xl.appendingPathComponent("workbook.xml"), workbook)
        let rels = RelsReader()
        parse(xl.appendingPathComponent("_rels/workbook.xml.rels"), rels)
        let strings = SharedStringsReader()
        parse(xl.appendingPathComponent("sharedStrings.xml"), strings)
        let styles = StylesReader()
        parse(xl.appendingPathComponent("styles.xml"), styles)

        var sheets: [Sheet] = []
        for (name, rid) in workbook.sheets {
            guard let target = rels.targets[rid] else { continue }
            let path = target.hasPrefix("/") ? dir.appendingPathComponent(String(target.dropFirst())) : xl.appendingPathComponent(target)
            let reader = SheetReader(strings: strings.strings, dateStyles: styles.dateStyles)
            parse(path, reader)
            sheets.append(Sheet(name: name, rows: reader.rows))
        }
        if sheets.isEmpty {   // no workbook listing: take every worksheet file there is
            let folder = xl.appendingPathComponent("worksheets")
            for file in ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "xml" {
                let reader = SheetReader(strings: strings.strings, dateStyles: styles.dateStyles)
                parse(file, reader)
                sheets.append(Sheet(name: file.deletingPathExtension().lastPathComponent, rows: reader.rows))
            }
        }
        return sheets
    }

    static func readODS(_ url: URL) throws -> [Sheet] {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = ODSReader()
        parse(dir.appendingPathComponent("content.xml"), reader)
        return reader.sheets
    }

    // MARK: Writing

    static func delimited(_ rows: [[String]], _ separator: String) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(separator) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: separator)
        }.joined(separator: "\n") + "\n"
    }

    /// The first row names the fields; each later row becomes an object.
    static func json(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "[]\n" }
        let keys = header.enumerated().map { $1.isEmpty ? "Column \($0 + 1)" : $1 }
        let objects: [[String: String]] = rows.dropFirst().map { row in
            Dictionary(keys.enumerated().map { ($1, $0 < row.count ? row[$0] : "") }, uniquingKeysWith: { a, _ in a })
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func html(_ sheets: [Sheet]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var out = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica,sans-serif;font-size:11px}table{border-collapse:collapse;margin-bottom:18px}th,td{border:1px solid #bbb;padding:3px 6px;text-align:left;vertical-align:top}th{background:#eee}h2{font-size:14px}</style></head><body>\n"
        for sheet in sheets {
            if sheets.count > 1 { out += "<h2>\(esc(sheet.name))</h2>\n" }
            out += "<table>\n"
            for (i, row) in sheet.rows.enumerated() {
                let tag = i == 0 ? "th" : "td"
                out += "<tr>" + row.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
            }
            out += "</table>\n"
        }
        return out + "</body></html>\n"
    }

    @MainActor
    private static func attributed(_ html: String) throws -> NSAttributedString {
        guard let data = html.data(using: .utf8),
              let text = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { throw ConvertError("Couldn't lay out the table.") }
        return text
    }

    /// A minimal, valid .xlsx: numbers stay numbers, everything else is text.
    static func writeXLSX(_ sheets: [Sheet], to out: URL) throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: Converter.controlCharacters, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func column(_ index: Int) -> String {
            var n = index + 1, name = ""
            while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
            return name
        }
        var parts: [String: String] = [:]
        var overrides = ""
        var sheetList = ""
        var relations = ""
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = column(c) + String(r + 1)
                    if Double(value) != nil, !value.hasPrefix("0") || value == "0" || value.hasPrefix("0.") {
                        xml += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                    } else {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(value))</t></is></c>"
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            parts["xl/worksheets/sheet\(n).xml"] = xml
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            let title = String(esc(sheet.name.isEmpty ? "Sheet\(n)" : sheet.name).prefix(31))
            sheetList += "<sheet name=\"\(title)\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            relations += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
        }
        parts["[Content_Types].xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(overrides)</Types>"
        parts["_rels/.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        parts["xl/workbook.xml"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetList)</sheets></workbook>"
        parts["xl/_rels/workbook.xml.rels"] = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relations)</Relationships>"
        try Converter.writeZip(parts, to: out)
    }

    // MARK: XML readers

    final class WorkbookReader: NSObject, XMLParserDelegate {
        var sheets: [(name: String, rid: String)] = []
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            guard name == "sheet" || name.hasSuffix(":sheet") else { return }
            let rid = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value ?? ""
            sheets.append((a["name"] ?? "Sheet\(sheets.count + 1)", rid))
        }
    }

    final class RelsReader: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "Relationship", let id = a["Id"], let target = a["Target"] { targets[id] = target }
        }
    }

    final class SharedStringsReader: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current: String?
        private var inText = false
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "si" { current = "" }
            if name == "t" { inText = true }
            if name == "rPh" { inText = false; current.map { _ in } }   // phonetic hints are not part of the text
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inText { current? += s } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current ?? ""); current = nil }
        }
    }

    /// Which cell styles (by index) show a date, from built-in date formats or custom ones with d/m/y in them.
    final class StylesReader: NSObject, XMLParserDelegate {
        var dateStyles: Set<Int> = []
        private var customDates: Set<Int> = []
        private var inCellXfs = false
        private var xfIndex = 0
        private static let builtInDates: Set<Int> = Set(14...22).union([45, 46, 47])
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "numFmt":
                if let id = Int(a["numFmtId"] ?? ""), let code = a["formatCode"]?.lowercased() {
                    let cleaned = code.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*""#, with: "", options: .regularExpression)
                    if cleaned.contains("y") || cleaned.contains("d") || (cleaned.contains("m") && cleaned.contains("h")) { customDates.insert(id) }
                }
            case "cellXfs": inCellXfs = true; xfIndex = 0
            case "xf" where inCellXfs:
                if let id = Int(a["numFmtId"] ?? ""), Self.builtInDates.contains(id) || customDates.contains(id) { dateStyles.insert(xfIndex) }
                xfIndex += 1
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inCellXfs = false }
        }
    }

    final class SheetReader: NSObject, XMLParserDelegate {
        var rows: [[String]] = []
        private let strings: [String]
        private let dateStyles: Set<Int>
        private var row: [String] = []
        private var cellColumn = 0
        private var cellType = ""
        private var cellStyle = 0
        private var value = ""
        private var capturing = false
        private var nextRow = 0

        init(strings: [String], dateStyles: Set<Int>) {
            self.strings = strings
            self.dateStyles = dateStyles
        }

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "row":
                // Rows can skip numbers (empty rows aren't stored); keep them, so line numbers match the sheet.
                if let r = Int(a["r"] ?? ""), r - 1 > nextRow { rows += Array(repeating: [], count: r - 1 - nextRow) }
                row = []
            case "c":
                cellType = a["t"] ?? "n"
                cellStyle = Int(a["s"] ?? "") ?? 0
                cellColumn = a["r"].map(Self.columnIndex) ?? row.count
                value = ""
            case "v", "t":
                capturing = true
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { if capturing { value += s } }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": capturing = false
            case "c":
                var text = value
                switch cellType {
                case "s": text = Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
                case "b": text = value == "1" ? "TRUE" : "FALSE"
                case "n" where dateStyles.contains(cellStyle): text = Double(value).map(Self.date) ?? value
                case "n": text = Double(value).map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int64($0)) : String($0) } ?? value
                default: break   // inlineStr, str (formula text), e (error)
                }
                if cellColumn > row.count { row += Array(repeating: "", count: cellColumn - row.count) }
                if cellColumn < row.count { row[cellColumn] = text } else { row.append(text) }
            case "row":
                rows.append(row)
                nextRow = rows.count
            default: break
            }
        }

        static func columnIndex(_ ref: String) -> Int {
            var n = 0
            for ch in ref.uppercased() {
                guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
                n = n * 26 + Int(a - 64)
            }
            return max(0, n - 1)
        }

        /// Excel stores dates as days since 30 Dec 1899.
        static func date(_ serial: Double) -> String {
            let date = Date(timeIntervalSince1970: (serial - 25569) * 86400)
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = serial == serial.rounded() ? "yyyy-MM-dd" : serial < 1 ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
            return f.string(from: date)
        }
    }

    /// OpenDocument: table:table → table:table-row → table:table-cell, with repeats for runs of equal cells.
    final class ODSReader: NSObject, XMLParserDelegate {
        var sheets: [Sheet] = []
        private var rows: [[String]] = []
        private var row: [String] = []
        private var rowRepeat = 1
        private var cellRepeat = 1
        private var cellValue: String?
        private var cellText = ""
        private var paragraphs = 0
        private var inText = false

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "table:table": rows = []; sheets.append(Sheet(name: a["table:name"] ?? "Sheet\(sheets.count + 1)", rows: []))
            case "table:table-row": row = []; rowRepeat = Int(a["table:number-rows-repeated"] ?? "") ?? 1
            case "table:table-cell", "table:covered-table-cell":
                cellRepeat = Int(a["table:number-columns-repeated"] ?? "") ?? 1
                cellValue = a["office:date-value"] ?? a["office:time-value"] ?? a["office:boolean-value"].map { $0 == "true" ? "TRUE" : "FALSE" }
                    ?? (["float", "percentage", "currency"].contains(a["office:value-type"] ?? "") ? a["office:value"] : nil)
                cellText = ""
                paragraphs = 0
            case "text:p": if paragraphs > 0 { cellText += "\n" }; paragraphs += 1; inText = true
            case "text:s": cellText += String(repeating: " ", count: Int(a["text:c"] ?? "") ?? 1)
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { if inText { cellText += s } }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "text:p": inText = false
            case "table:table-cell", "table:covered-table-cell":
                let text = cellValue ?? cellText
                // Sheets pad the right edge with thousands of repeated empty cells; skip those.
                if text.isEmpty && cellRepeat > 50 { break }
                row += Array(repeating: text, count: min(cellRepeat, 1000))
            case "table:table-row":
                while row.last == "" { row.removeLast() }
                if row.isEmpty && rowRepeat > 50 { break }   // likewise at the bottom
                rows += Array(repeating: row, count: min(rowRepeat, 10000))
            case "table:table":
                while rows.last?.isEmpty == true { rows.removeLast() }
                sheets[sheets.count - 1].rows = rows
            default: break
            }
        }
    }
}
