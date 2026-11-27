import SwiftData
import SwiftUI

/// Asks the open notebook or PDF to show one of its pages. The screen
/// showing that notebook or PDF takes it; one that has just opened for it
/// takes it too.
@MainActor
@Observable
final class PalNavigator {
    static let shared = PalNavigator()

    struct Request: Equatable {
        let id = UUID()
        let itemID: UUID
        /// A notebook's page.
        let pageID: UUID?
        /// A PDF's page, from 0.
        let pageIndex: Int?
        let date = Date()
    }

    private(set) var request: Request?

    func show(notebook: UUID, page: UUID) {
        request = Request(itemID: notebook, pageID: page, pageIndex: nil)
    }

    func show(pdf: UUID, pageIndex: Int) {
        request = Request(itemID: pdf, pageID: nil, pageIndex: pageIndex)
    }

    /// A recent request for this notebook or PDF, if there is one.
    func pending(for itemID: UUID) -> Request? {
        guard let request, request.itemID == itemID, Date.now.timeIntervalSince(request.date) < 15 else { return nil }
        return request
    }

    func done(_ handled: Request) {
        if request?.id == handled.id { request = nil }
    }
}

/// What the study pal can do in the app itself, like you can: see your
/// library, open, create, rename and delete notebooks and PDFs, and add,
/// rename, reorder, delete and go to pages. Deleting always asks you
/// first, in a card, because it can't be undone.
@MainActor
enum PalAppTools {
    static func definitions() -> [[String: Any]] {
        let notebook: [String: Any] = ["type": ["string", "null"], "description": "The notebook's item_id. Null for the notebook they're using."]
        let item: [String: Any] = ["type": "string", "description": "The notebook's or PDF's item_id (from list_library, or the top of their message)."]
        let pageNumber: [String: Any] = ["type": "integer", "description": "The page number, from 1."]
        return [
            PalTools.function("list_library",
                              "List all their notebooks and PDFs with their item_ids, page counts and when they were last used.",
                              [:]),
            PalTools.function("list_pages",
                              "List a notebook's pages, in order, with their numbers and titles.",
                              ["notebook_id": notebook]),
            PalTools.function("open_item",
                              "Open a notebook or PDF on their screen, in place of what's open (or bring forward its own window, if it has one), optionally at a page. With new_window, it opens in a window of its own instead, so they can put it beside another.",
                              ["item_id": item,
                               "page": ["type": ["integer", "null"], "description": "A page to show, from 1, or null."],
                               "new_window": ["type": "boolean", "description": "Open it in a window of its own. Only when they ask for a new window."]]),
            PalTools.function("close_item",
                              "Close a notebook or PDF: one in a window of its own closes that window; one in the main window goes back to the library. Use it when they're done with something, or ask you to close it, like a question PDF you opened beside their notes.",
                              ["item_id": ["type": "string", "description": "The notebook's or PDF's item_id, or its open page's name (N1, P1)."]]),
            PalTools.function("go_to_page",
                              "Show another page of a notebook or PDF: the one they're using unless item_id says otherwise.",
                              ["item_id": ["type": ["string", "null"], "description": "The notebook's or PDF's item_id, or null for the one they're using."],
                               "page": pageNumber]),
            PalTools.function("create_notebook",
                              "Make a new notebook with one blank page.",
                              ["title": ["type": "string"], "open": ["type": "boolean", "description": "Open it afterwards."]]),
            PalTools.function("rename_item",
                              "Rename a notebook or PDF.",
                              ["item_id": item, "title": ["type": "string"]]),
            PalTools.function("delete_from_library",
                              "Delete a notebook (with all its pages) or a PDF (with its notes). Memor asks them to confirm in a card first; it can't be undone.",
                              ["item_id": item]),
            PalTools.function("add_page",
                              "Add a blank page to a notebook.",
                              ["notebook_id": notebook,
                               "after_page": ["type": ["integer", "null"], "description": "Put it after this page number; null for the end."],
                               "title": ["type": ["string", "null"], "description": "A title for it, or null for just its number."],
                               "open": ["type": "boolean", "description": "Go to it afterwards."]]),
            PalTools.function("rename_page",
                              "Rename a notebook page. An empty title goes back to its number.",
                              ["notebook_id": notebook, "page": pageNumber, "title": ["type": "string"]]),
            PalTools.function("move_page",
                              "Move a notebook page to another position.",
                              ["notebook_id": notebook, "page": pageNumber, "to": ["type": "integer", "description": "Its new position, from 1."]]),
            PalTools.function("delete_page",
                              "Delete a notebook page with everything on it. Memor asks them to confirm in a card first; it can't be undone. A notebook keeps at least one page.",
                              ["notebook_id": notebook, "page": pageNumber]),
            PalTools.function("set_my_name",
                              "Change your own name, when they give you one.",
                              ["name": ["type": "string"]]),
        ]
    }

    /// Runs an app tool. Nil when `name` isn't one.
    static func run(name: String, input: [String: Any], context: PalTools.Context) async -> PalTools.Outcome? {
        guard let modelContext = PalLibrary.container?.mainContext else {
            return names.contains(name) ? .text("The library isn't ready.", isError: true) : nil
        }
        switch name {
        case "list_library": return listLibrary(modelContext)
        case "list_pages": return listPages(input, modelContext)
        case "open_item": return openItem(input, modelContext)
        case "close_item": return closeItem(input, modelContext)
        case "go_to_page": return goToPage(input, modelContext)
        case "create_notebook": return createNotebook(input, modelContext)
        case "rename_item": return renameItem(input, modelContext)
        case "delete_from_library": return await deleteItem(input, modelContext, context: context)
        case "add_page": return addPage(input, modelContext)
        case "rename_page": return renamePage(input, modelContext)
        case "move_page": return movePage(input, modelContext)
        case "delete_page": return await deletePage(input, modelContext, context: context)
        case "set_my_name": return setName(input)
        default: return nil
        }
    }

    private static let names: Set<String> = ["list_library", "list_pages", "open_item", "close_item", "go_to_page", "create_notebook", "rename_item", "delete_from_library", "add_page", "rename_page", "move_page", "delete_page", "set_my_name"]

    // MARK: Library

    private static func listLibrary(_ context: ModelContext) -> PalTools.Outcome {
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))) ?? []
        let pdfs = (try? context.fetch(FetchDescriptor<PDFItem>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]))) ?? []
        var lines: [String] = ["Notebooks:"]
        lines += notebooks.map { notebook in
            let count = notebook.sortedPages.count
            return "- “\(notebook.title)” (item_id \(notebook.id.uuidString)): \(count) page\(count == 1 ? "" : "s"), edited \(notebook.modifiedAt.formatted(.relative(presentation: .named)))"
        }
        if notebooks.isEmpty { lines.append("(none)") }
        lines.append("PDFs:")
        lines += pdfs.map { pdf in
            "- “\(pdf.title)” (item_id \(pdf.id.uuidString)): \(pdf.pageCount) pages, opened \(pdf.lastOpenedAt.formatted(.relative(presentation: .named)))"
        }
        if pdfs.isEmpty { lines.append("(none)") }
        return .text(lines.joined(separator: "\n"))
    }

    private static func listPages(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let notebook = notebook(input["notebook_id"], context) else { return noNotebook }
        let current = notebook.currentPageID
        let lines = notebook.sortedPages.enumerated().map { index, page in
            "\(index + 1). “\(page.displayTitle(number: index + 1))”" + (page.id == current ? " (the page last open)" : "")
        }
        return .text("Pages of “\(notebook.title)”:\n" + lines.joined(separator: "\n"))
    }

    private static func openItem(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let id = uuid(input["item_id"]) else { return .text("`item_id` must be an item_id from list_library.", isError: true) }
        let page = number(input["page"])
        let newWindow = input["new_window"] as? Bool == true
        let how = newWindow ? " in a window of its own" : ""
        if let notebook = fetchNotebook(id, context) {
            if let page {
                guard let target = notebook.sortedPages[safe: page - 1] else { return .text("“\(notebook.title)” has only \(notebook.sortedPages.count) pages.", isError: true) }
                notebook.currentPageID = target.id
                PalNavigator.shared.show(notebook: notebook.id, page: target.id)
            }
            open(.notebook(notebook.id), inNewWindow: newWindow)
            return .text("Opened “\(notebook.title)”\(how)\(page.map { " at page \($0)" } ?? "").")
        }
        if let pdf = fetchPDF(id, context) {
            if let page { PalNavigator.shared.show(pdf: pdf.id, pageIndex: max(page - 1, 0)) }
            open(.pdf(pdf.id), inNewWindow: newWindow)
            return .text("Opened “\(pdf.title)”\(how)\(page.map { " at page \($0)" } ?? "").")
        }
        return unknownItem
    }

    private static func closeItem(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let value = string(input["item_id"]), !value.isEmpty else {
            return .text("`item_id` must be an item_id, or an open page's name like P1.", isError: true)
        }
        let target: OpenTarget
        let title: String
        if let id = UUID(uuidString: value) {
            if let notebook = fetchNotebook(id, context) {
                target = .notebook(id)
                title = notebook.title
            } else if let pdf = fetchPDF(id, context) {
                target = .pdf(id)
                title = pdf.title
            } else {
                return unknownItem
            }
        } else if let page = PalWorkspace.shared.page(shortID: value) {
            target = page.palKind == .notebook ? .notebook(page.palItemID) : .pdf(page.palItemID)
            title = page.palItemTitle
        } else {
            return .text("No open page is called \(value). The open ones are at the top of the message.", isError: true)
        }
        switch AppNavigator.shared.close(target) {
        case .window: return .text("Closed the window with “\(title)”.")
        case .mainWindow: return .text("Closed “\(title)”; the main window shows the library.")
        case .notOpen: return .text("“\(title)” isn't open.", isError: true)
        }
    }

    private static func goToPage(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let page = number(input["page"]), page >= 1 else { return .text("`page` must be a page number from 1.", isError: true) }
        let id = uuid(input["item_id"]) ?? PalWorkspace.shared.focusedPage?.palItemID
        guard let id else { return .text("Say which notebook or PDF (its item_id): they aren't in one now.", isError: true) }
        if let notebook = fetchNotebook(id, context) {
            guard let target = notebook.sortedPages[safe: page - 1] else { return .text("“\(notebook.title)” has only \(notebook.sortedPages.count) pages.", isError: true) }
            notebook.currentPageID = target.id
            PalNavigator.shared.show(notebook: notebook.id, page: target.id)
            open(.notebook(notebook.id))
            return .text("Went to page \(page) of “\(notebook.title)”.", changedPage: false)
        }
        if let pdf = fetchPDF(id, context) {
            guard page <= max(pdf.pageCount, 1) else { return .text("“\(pdf.title)” has only \(pdf.pageCount) pages.", isError: true) }
            PalNavigator.shared.show(pdf: pdf.id, pageIndex: page - 1)
            open(.pdf(pdf.id))
            return .text("Went to page \(page) of “\(pdf.title)”.")
        }
        return unknownItem
    }

    private static func createNotebook(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        let title = string(input["title"]) ?? ""
        let notebook = Notebook()
        if !title.isEmpty { notebook.title = title }
        context.insert(notebook)
        let firstPage = notebook.ensureFirstPage(in: context)
        Thumbnails.writeBlankNotebookThumbnail(id: firstPage.id)
        try? context.save()
        if input["open"] as? Bool == true { open(.notebook(notebook.id)) }
        return .text("Made the notebook “\(notebook.title)” (item_id \(notebook.id.uuidString)).", changedPage: true)
    }

    private static func renameItem(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let id = uuid(input["item_id"]) else { return .text("`item_id` must be an item_id from list_library.", isError: true) }
        guard let title = string(input["title"]), !title.isEmpty else { return .text("`title` can't be empty.", isError: true) }
        if let notebook = fetchNotebook(id, context) {
            let old = notebook.title
            notebook.title = title
            try? context.save()
            return .text("Renamed the notebook “\(old)” to “\(title)”.", changedPage: true)
        }
        if let pdf = fetchPDF(id, context) {
            let old = pdf.title
            pdf.title = title
            try? context.save()
            return .text("Renamed the PDF “\(old)” to “\(title)”.", changedPage: true)
        }
        return unknownItem
    }

    private static func deleteItem(_ input: [String: Any], _ context: ModelContext, context tools: PalTools.Context) async -> PalTools.Outcome {
        guard let id = uuid(input["item_id"]) else { return .text("`item_id` must be an item_id from list_library.", isError: true) }
        if let notebook = fetchNotebook(id, context) {
            let title = notebook.title
            guard await confirm("Delete the notebook “\(title)” and all its pages? This can't be undone.", context: tools) else {
                return .text("They didn't confirm, so “\(title)” wasn't deleted.")
            }
            guard let notebook = fetchNotebook(id, context) else { return unknownItem }
            FileStore.removeItem(at: FileStore.thumbnailURL(for: notebook.id))
            for page in notebook.pages ?? [] {
                FileStore.removeItem(at: FileStore.thumbnailURL(for: page.id))
            }
            context.delete(notebook)
            try? context.save()
            return .text("Deleted the notebook “\(title)”.", changedPage: true)
        }
        if let pdf = fetchPDF(id, context) {
            let title = pdf.title
            guard await confirm("Delete the PDF “\(title)” and your notes on it? This can't be undone.", context: tools) else {
                return .text("They didn't confirm, so “\(title)” wasn't deleted.")
            }
            guard let pdf = fetchPDF(id, context) else { return unknownItem }
            FileStore.removeItem(at: FileStore.pdfURL(fileName: pdf.fileName))
            FileStore.removeItem(at: FileStore.thumbnailURL(for: pdf.id))
            context.delete(pdf)
            try? context.save()
            return .text("Deleted the PDF “\(title)”.", changedPage: true)
        }
        return unknownItem
    }

    // MARK: Pages

    private static func addPage(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let notebook = notebook(input["notebook_id"], context) else { return noNotebook }
        let pages = notebook.sortedPages
        let after = number(input["after_page"]).flatMap { pages[safe: $0 - 1] } ?? pages.last
        let page = notebook.addPage(after: after, in: context)
        if let title = string(input["title"]), !title.isEmpty { page.title = title }
        Thumbnails.writeBlankNotebookThumbnail(id: page.id)
        try? context.save()
        let position = (notebook.sortedPages.firstIndex { $0.id == page.id } ?? 0) + 1
        if input["open"] as? Bool == true {
            notebook.currentPageID = page.id
            PalNavigator.shared.show(notebook: notebook.id, page: page.id)
            open(.notebook(notebook.id))
        }
        return .text("Added page \(position) to “\(notebook.title)”.", changedPage: true)
    }

    private static func renamePage(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let notebook = notebook(input["notebook_id"], context) else { return noNotebook }
        guard let number = number(input["page"]), let page = notebook.sortedPages[safe: number - 1] else {
            return .text("That page number isn't in “\(notebook.title)”.", isError: true)
        }
        let title = string(input["title"]) ?? ""
        page.title = title == "Page \(number)" ? "" : title
        try? context.save()
        return .text(title.isEmpty ? "Page \(number) goes by its number again." : "Renamed page \(number) to “\(title)”.", changedPage: true)
    }

    private static func movePage(_ input: [String: Any], _ context: ModelContext) -> PalTools.Outcome {
        guard let notebook = notebook(input["notebook_id"], context) else { return noNotebook }
        var ordered = notebook.sortedPages
        guard let from = number(input["page"]), ordered.indices.contains(from - 1),
              let to = number(input["to"]) else {
            return .text("`page` and `to` must be page numbers in “\(notebook.title)”.", isError: true)
        }
        let page = ordered.remove(at: from - 1)
        let position = min(max(to - 1, 0), ordered.count)
        ordered.insert(page, at: position)
        notebook.applyPageOrder(ordered)
        try? context.save()
        return .text("Moved page \(from) to position \(position + 1).", changedPage: true)
    }

    private static func deletePage(_ input: [String: Any], _ context: ModelContext, context tools: PalTools.Context) async -> PalTools.Outcome {
        guard let notebook = notebook(input["notebook_id"], context) else { return noNotebook }
        let pages = notebook.sortedPages
        guard pages.count > 1 else { return .text("A notebook keeps at least one page.", isError: true) }
        guard let number = number(input["page"]), let page = pages[safe: number - 1] else {
            return .text("That page number isn't in “\(notebook.title)”.", isError: true)
        }
        let pageID = page.id
        let name = page.displayTitle(number: number)
        guard await confirm("Delete page \(number) (“\(name)”) of “\(notebook.title)” with everything on it? This can't be undone.", context: tools) else {
            return .text("They didn't confirm, so the page wasn't deleted.")
        }
        // If it's on screen, show the page next to it first.
        if notebook.currentPageID == pageID,
           let neighbor = pages[safe: number] ?? pages[safe: number - 2] {
            notebook.currentPageID = neighbor.id
            PalNavigator.shared.show(notebook: notebook.id, page: neighbor.id)
            try? await Task.sleep(for: .milliseconds(700))
        }
        guard let page = notebook.sortedPages.first(where: { $0.id == pageID }) else { return .text("That page is already gone.") }
        if notebook.currentPageID == pageID { notebook.currentPageID = nil }
        FileStore.removeItem(at: FileStore.thumbnailURL(for: pageID))
        context.delete(page)
        notebook.applyPageOrder(notebook.sortedPages.filter { $0.id != pageID })
        try? context.save()
        return .text("Deleted page \(number) (“\(name)”).", changedPage: true)
    }

    private static func setName(_ input: [String: Any]) -> PalTools.Outcome {
        guard let name = string(input["name"]), !name.isEmpty else { return .text("`name` can't be empty.", isError: true) }
        UserDefaults.standard.set(String(name.prefix(30)), forKey: StudyPalCharacter.nameKey)
        return .text("Your name is \(name.prefix(30)) now.")
    }

    // MARK: Helpers

    private static let unknownItem = PalTools.Outcome.text("No notebook or PDF has that item_id. Call list_library for the ids.", isError: true)
    private static let noNotebook = PalTools.Outcome.text("Say which notebook (its item_id, from list_library): they aren't in one now.", isError: true)

    /// Shows a notebook or PDF in the main window (or its own window, if it
    /// has one), or opens it in a new window of its own.
    private static func open(_ target: OpenTarget, inNewWindow: Bool = false) {
        if inNewWindow {
            AppNavigator.shared.openInNewWindow(target)
        } else {
            // She may be in a notebook's or PDF's own window: the main
            // window comes forward to show it.
            AppNavigator.shared.open(target, showingMainWindow: true)
        }
    }

    /// Shows a card asking them to confirm, and waits.
    private static func confirm(_ question: String, context: PalTools.Context) async -> Bool {
        let answer = await context.offerChoices(question, [
            PalChoice.Option(id: 0, label: "Delete", imageURL: nil),
            PalChoice.Option(id: 1, label: "Keep It", imageURL: nil),
        ])
        return answer.hasPrefix("They chose option 1")
    }

    /// The notebook named, or the one they're using.
    private static func notebook(_ value: Any?, _ context: ModelContext) -> Notebook? {
        if let id = uuid(value) { return fetchNotebook(id, context) }
        guard let page = PalWorkspace.shared.focusedPage, page.palKind == .notebook else { return nil }
        return fetchNotebook(page.palItemID, context)
    }

    private static func fetchNotebook(_ id: UUID, _ context: ModelContext) -> Notebook? {
        var descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func fetchPDF(_ id: UUID, _ context: ModelContext) -> PDFItem? {
        var descriptor = FetchDescriptor<PDFItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.intValue
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
