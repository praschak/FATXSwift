import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FATXCore
import FATXService

private let fatxDragType = NSPasteboard.PasteboardType("com.fatxswift.browser.item")
private struct InternalDrag: Codable { let connection: String; let path: String }

private final class FATXPromise: NSFilePromiseProvider {
    var internalData: Data?
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [fatxDragType]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == fatxDragType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == fatxDragType ? internalData : super.pasteboardPropertyList(forType: type)
    }
}
private final class FileExporter: NSObject, NSFilePromiseProviderDelegate {
    let item: BrowserItem
    let request: BrowserRequest
    let client: BrowserClient
    init(item: BrowserItem, request: BrowserRequest, client: BrowserClient) { self.item = item; self.request = request; self.client = client }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { item.name }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        var r = request; r.command = .exportItems; r.paths = [item.path]; r.destination = url.path
        Task {
            do { _ = try await client.send(r); completionHandler(nil) }
            catch { completionHandler(error) }
        }
    }
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { OperationQueue.main }
}

@MainActor
struct FileTable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(), scroll = NSScrollView()
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true
        table.rowHeight = 30; table.style = .fullWidth
        for (id, title, width) in [("name", "Name", 390.0), ("kind", "Kind", 105.0), ("size", "Size", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openItem)
        table.registerForDraggedTypes([.fileURL, fatxDragType])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = context.coordinator; table.menu = menu
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        let rows = coordinator.sorted(model.visibleItems)
        if coordinator.rows != rows {
            coordinator.rows = rows; coordinator.table?.reloadData()
        }
        let selected = IndexSet(rows.indices.filter { model.selection.contains(rows[$0].path) })
        if coordinator.table?.selectedRowIndexes != selected { coordinator.table?.selectRowIndexes(selected, byExtendingSelection: false) }
        coordinator.table?.alphaValue = model.busy ? 0.55 : 1
    }
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: BrowserModel
        weak var table: NSTableView?
        var rows: [BrowserItem] = []
        private var exporters: [FileExporter] = []
        init(_ model: BrowserModel) { self.model = model }
        func sorted(_ items: [BrowserItem]) -> [BrowserItem] {
            let descriptor = table?.sortDescriptors.first
            return items.sorted { a, b in
                if a.directory != b.directory { return a.directory }
                let ascending = descriptor?.ascending ?? true
                let comparison: ComparisonResult
                if descriptor?.key == "size" && a.size != b.size { comparison = a.size < b.size ? .orderedAscending : .orderedDescending }
                else if descriptor?.key == "kind", URL(fileURLWithPath: a.name).pathExtension != URL(fileURLWithPath: b.name).pathExtension {
                    comparison = URL(fileURLWithPath: a.name).pathExtension.localizedStandardCompare(URL(fileURLWithPath: b.name).pathExtension)
                } else { comparison = a.name.localizedStandardCompare(b.name) }
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            rows = sorted(rows); tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(rows.indices.filter { model.selection.contains(rows[$0].path) }), byExtendingSelection: false)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
            let item = rows[row]
            if key == "name" {
                let cell = NSTableCellView(), icon = NSImageView(), label = NSTextField(labelWithString: item.name)
                icon.image = NSImage(systemSymbolName: item.directory ? "folder.fill" : "doc", accessibilityDescription: item.directory ? "Folder" : "File")
                icon.contentTintColor = item.directory ? .systemBlue : .secondaryLabelColor
                icon.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(icon); cell.addSubview(label)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 19), icon.heightAnchor.constraint(equalToConstant: 19),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }
            let text = key == "kind" ? (item.directory ? "Folder" : (URL(fileURLWithPath: item.name).pathExtension.uppercased().isEmpty ? "File" : URL(fileURLWithPath: item.name).pathExtension.uppercased() + " file")) : (item.directory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
            let label = NSTextField(labelWithString: text); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
            return label
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil })
        }
        @objc func openItem() { if !model.busy { model.openSelection() } }
        @objc func renameItem() { model.renameSelection() }
        @objc func moveItems() { model.moveSelection() }
        @objc func exportItems() { model.exportPanel() }
        @objc func deleteItems() { model.deleteSelection() }
        @objc func previewItem() { model.previewSelection() }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); guard !model.busy, let table else { return }
            if rows.indices.contains(table.clickedRow), !table.selectedRowIndexes.contains(table.clickedRow) { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
            guard !model.selection.isEmpty else { return }
            let commands: [(String, Selector)] = [("Open", #selector(openItem)), ("Export…", #selector(exportItems)), ("Preview…", #selector(previewItem)), ("Rename…", #selector(renameItem)), ("Move To…", #selector(moveItems)), ("Delete…", #selector(deleteItems))]
            for (title, selector) in commands {
                let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self
                entry.isEnabled = !["Rename…", "Preview…", "Open"].contains(title) || model.selection.count == 1
                menu.addItem(entry)
            }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard !model.busy, rows.indices.contains(row) else { return nil }
            let item = rows[row], exporter = FileExporter(item: item, request: model.request(.exportItems), client: model.client)
            exporters.append(exporter)
            let provider = FATXPromise(fileType: item.directory ? UTType.folder.identifier : (UTType(filenameExtension: URL(fileURLWithPath: item.name).pathExtension)?.identifier ?? UTType.data.identifier), delegate: exporter)
            provider.internalData = try? JSONEncoder().encode(InternalDrag(connection: model.connectionKey, path: item.path))
            return provider
        }
        func target(_ row: Int, _ operation: NSTableView.DropOperation) -> String {
            operation == .on && rows.indices.contains(row) && rows[row].directory ? rows[row].path : model.currentDirectory
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard model.connected && !model.busy else { return [] }
            if !(operation == .on && rows.indices.contains(row) && rows[row].directory) { tableView.setDropRow(-1, dropOperation: .above) }
            if info.draggingPasteboard.availableType(from: [fatxDragType]) != nil { return .move }
            return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            guard !model.busy else { return false }
            let directory = target(row, operation), board = info.draggingPasteboard
            let internalItems = (board.pasteboardItems ?? []).compactMap { item -> InternalDrag? in
                guard let bytes = item.data(forType: fatxDragType) else { return nil }; return try? JSONDecoder().decode(InternalDrag.self, from: bytes)
            }
            if !internalItems.isEmpty {
                guard internalItems.allSatisfy({ $0.connection == model.connectionKey }) else { model.showError(FATXError("Cross-volume drag moves are not supported. Export and import instead.")); return false }
                model.movePaths(internalItems.map(\.path), into: directory); return true
            }
            guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            model.importURLs(urls, into: directory); return true
        }
    }
}
