// Rename one file, or many at once (replace text, add text, name + number, change case),
// with a live before → after list. Names change in place; nothing is copied.

import SwiftUI
import AppKit

enum Renamer {
    /// A quick prompt with the name (without its extension) selected, like Finder's and Explorer's rename.
    @MainActor
    static func renameOne(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = url.deletingLastPathComponent().path
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            let base = (url.lastPathComponent as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        do {
            guard !name.contains("/") else { throw ConvertError("A name can't contain “/”.") }
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path), target.path.lowercased() != url.path.lowercased() {
                throw ConvertError("There's already an item called “\(name)” there.")
            }
            try FileManager.default.moveItem(at: url, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
final class BatchRenameModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case replace = "Replace text", add = "Add text", number = "Name + number", textCase = "Change case"
        var id: String { rawValue }
    }

    let urls: [URL]
    weak var window: NSWindow?
    @Published var mode: Mode = .number
    @Published var find = ""
    @Published var replaceWith = ""
    @Published var useRegex = false
    @Published var matchCase = false
    @Published var addText = ""
    @Published var addAfter = true
    @Published var baseName = ""
    @Published var start = 1
    @Published var digits = 3
    @Published var separator = " "
    @Published var caseStyle = "lower"
    @Published var error: String?

    init(urls: [URL]) {
        // Number in name order ("IMG 2" before "IMG 10"), as Explorer does.
        self.urls = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        baseName = (self.urls.first?.deletingPathExtension().lastPathComponent ?? "File")
            .replacingOccurrences(of: #"[ _-]*\d+$"#, with: "", options: .regularExpression)
        if baseName.isEmpty { baseName = "File" }
    }

    /// The new name for each file, extension kept.
    func newName(_ url: URL, index: Int) -> String {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var name: String
        switch mode {
        case .replace:
            guard !find.isEmpty else { return url.lastPathComponent }
            if useRegex {
                let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
                guard let re = try? NSRegularExpression(pattern: find, options: options) else { return url.lastPathComponent }
                name = re.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: replaceWith)
            } else {
                name = base.replacingOccurrences(of: find, with: replaceWith, options: matchCase ? [] : [.caseInsensitive])
            }
        case .add:
            name = addAfter ? base + addText : addText + base
        case .number:
            let number = String(format: "%0\(max(1, digits))d", start + index)
            name = baseName + separator + number
        case .textCase:
            switch caseStyle {
            case "upper": name = base.uppercased()
            case "title": name = base.capitalized
            default: name = base.lowercased()
            }
        }
        return ext.isEmpty ? name : name + "." + ext
    }

    struct Row: Identifiable {
        let id = UUID()
        let old: String
        let new: String
        let problem: String?
    }

    var rows: [Row] {
        let names = urls.enumerated().map { newName($1, index: $0) }
        var seen: [String: Int] = [:]
        for n in names { seen[n.lowercased(), default: 0] += 1 }
        let ownNames = Set(urls.map { $0.lastPathComponent.lowercased() })
        return urls.enumerated().map { i, url in
            let new = names[i]
            var problem: String?
            if new.trimmingCharacters(in: .whitespaces).isEmpty || new.hasPrefix(".") { problem = "Empty name" }
            else if new.contains("/") { problem = "Contains /" }
            else if seen[new.lowercased(), default: 0] > 1 { problem = "Same name twice" }
            else if !ownNames.contains(new.lowercased()),
                    FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(new).path) {
                problem = "Already exists"
            }
            return Row(old: url.lastPathComponent, new: new, problem: problem)
        }
    }

    var canApply: Bool {
        let r = rows
        return r.allSatisfy { $0.problem == nil } && r.contains { $0.old != $0.new }
    }

    /// Two passes (via temporary names) so swaps like a → b, b → a work.
    func apply() {
        let fm = FileManager.default
        let targets = urls.enumerated().map { ($1, $1.deletingLastPathComponent().appendingPathComponent(newName($1, index: $0))) }
            .filter { $0.0.lastPathComponent != $0.1.lastPathComponent }
        var parked: [(URL, URL)] = []
        do {
            for (from, to) in targets {
                let temp = from.deletingLastPathComponent().appendingPathComponent(".elconvo-rename-\(UUID().uuidString)")
                try fm.moveItem(at: from, to: temp)
                parked.append((temp, to))
            }
            for (temp, to) in parked { try fm.moveItem(at: temp, to: to) }
            Ops.delivered(parked.map(\.1), closing: window)
        } catch {
            // Put anything still parked back under its old name.
            for (i, (temp, _)) in parked.enumerated() where fm.fileExists(atPath: temp.path) {
                try? fm.moveItem(at: temp, to: targets[i].0)
            }
            self.error = error.localizedDescription
        }
    }
}

struct BatchRenameView: View {
    @ObservedObject var model: BatchRenameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.mode) {
                ForEach(BatchRenameModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch model.mode {
                case .replace:
                    HStack {
                        TextField("Find", text: $model.find).textFieldStyle(.roundedBorder)
                        TextField("Replace with", text: $model.replaceWith).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Toggle("Match case", isOn: $model.matchCase)
                        Toggle("Regular expression", isOn: $model.useRegex).help("e.g. find (\\d+) and replace with Photo-$1")
                    }
                case .add:
                    HStack {
                        TextField("Text to add", text: $model.addText).textFieldStyle(.roundedBorder)
                        Picker("", selection: $model.addAfter) {
                            Text("after the name").tag(true)
                            Text("before the name").tag(false)
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                case .number:
                    HStack {
                        TextField("Name", text: $model.baseName).textFieldStyle(.roundedBorder)
                        Picker("", selection: $model.separator) {
                            Text("space").tag(" ")
                            Text("-").tag("-")
                            Text("_").tag("_")
                            Text("none").tag("")
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Stepper("Start at \(model.start)", value: $model.start, in: 0...99999)
                        Stepper("\(model.digits) digits", value: $model.digits, in: 1...6)
                    }
                case .textCase:
                    Picker("", selection: $model.caseStyle) {
                        Text("lowercase").tag("lower")
                        Text("UPPERCASE").tag("upper")
                        Text("Title Case").tag("title")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }

            Text("Extensions are kept. Numbering follows name order.").font(.caption).foregroundStyle(.secondary)

            List(model.rows) { row in
                HStack(spacing: 8) {
                    Text(row.old).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(row.new).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.problem != nil ? Color.red : row.new == row.old ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let problem = row.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
                .font(.system(size: 12))
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Text("\(model.urls.count) files").foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Cancel") { model.window?.close() }.keyboardShortcut(.cancelAction)
                Button("Rename \(model.urls.count) Files") { model.apply() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
            }
        }
        .padding(16)
    }
}
