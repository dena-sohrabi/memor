import PDFKit
import SwiftData
import UIKit
import UserNotifications

/// Options she wants you to pick from, shown in a small card: buttons, or
/// pictures in a grid. Tap one, or just tell her.
struct PalChoice: Identifiable {
    struct Option: Identifiable {
        let id: Int
        let label: String
        let imageURL: URL?
    }

    let id = UUID()
    let question: String
    let options: [Option]

    var hasPictures: Bool { options.contains { $0.imageURL != nil } }
}

/// What she's doing right now, like "Creating an image…", with an SF
/// Symbol to go with it. No symbol when she's only thinking.
struct PalActivity: Hashable {
    let text: String
    var symbol: String?

    static let thinking = PalActivity(text: "Thinking…")
}

/// Everything the study pal can do, as tools for her model: look closely
/// at a page, write by hand, add typed notes and pictures, mark things,
/// rearrange typed notes and pictures, highlight and read PDFs, search all
/// your notes, show options, set a reminder, and remember things. The same
/// tools whether you type to her or talk.
///
/// Your own handwriting is never moved or changed, and Undo takes back
/// anything she does.
@MainActor
enum PalTools {
    /// What a tool needs from the talk it's in.
    struct Context {
        /// What was circled with the message she's answering, if anything.
        let circle: PalCircle?
        /// Shows options and waits for the pick.
        let offerChoices: (_ question: String, _ options: [PalChoice.Option]) async -> String
    }

    /// What a tool did, for her: text, or text and pictures.
    struct Outcome {
        /// A string, or an array of `input_text` and `input_image` parts.
        var output: Any
        var isError = false
        /// It changed a page, so she can be pleased.
        var changedPage = false

        static func text(_ text: String, isError: Bool = false, changedPage: Bool = false) -> Outcome {
            Outcome(output: text, isError: isError, changedPage: changedPage)
        }
    }

    // MARK: Definitions

    /// The tools, in the Responses API's format.
    static func definitions(canDraw: Bool) -> [[String: Any]] {
        let page: [String: Any] = ["type": ["string", "null"], "description": "Which open page: N1, P1 and so on. Null for the one they're using."]
        let pdfPage: [String: Any] = ["type": ["integer", "null"], "description": "On a PDF, which of its pages, from 1. Null for the page they circled on, or else the one in view. Ignored on notebooks."]
        let x: [String: Any] = ["type": ["number", "null"], "description": "Left edge, in page points. Null to let Memor find a free spot beside what they circled, or in view."]
        let y: [String: Any] = ["type": ["number", "null"], "description": "Top edge, in page points. Null together with x."]
        let id: [String: Any] = ["type": "string", "description": "The item's id from get_page_items."]
        let color: [String: Any] = ["type": ["string", "null"], "description": "red, green, blue, orange, purple, pink, black or gray, or #RRGGBB. Null for the default."]
        let number: [String: Any] = ["type": "number"]
        let text: (String) -> [String: Any] = { ["type": "string", "description": $0] }

        var tools: [[String: Any]] = [
            ["type": "web_search"],
            function("look_at",
                     "See part of a page sharply, to read small or unclear handwriting, check working, or see what's off screen. Give an area in page points, or all four as null for everything on the page. With label_handwriting, each handwritten word gets a numbered pink box (h1, h2…) with the id to use in erase_handwriting and move_handwriting. Returns a picture and the area it shows.",
                     ["page": page, "pdf_page": pdfPage,
                      "x": ["type": ["number", "null"]], "y": ["type": ["number", "null"]],
                      "width": ["type": ["number", "null"]], "height": ["type": ["number", "null"]],
                      "label_handwriting": ["type": "boolean", "description": "Draw numbered boxes on the handwritten words."]]),
            function("get_page_items",
                     "List what's on a page with positions in page points (x grows to the right, y grows down): the area on screen, handwritten words with their ids (h1, h2…) and lines, typed notes with their text and ids, pictures, and on a PDF its highlights. Use it before placing something yourself or changing anything.",
                     ["page": page, "pdf_page": pdfPage]),
            function("erase_handwriting",
                     "Erase the student's own handwriting: words by their ids (from look_at with label_handwriting, or get_page_items), or every stroke lying mostly inside an area. Only erase what they asked for. Undo brings it back.",
                     ["page": page, "pdf_page": pdfPage,
                      "ids": ["type": "array", "items": ["type": "string"], "description": "Handwritten word ids, like h12. Empty to erase by area."],
                      "x": ["type": ["number", "null"]], "y": ["type": ["number", "null"]],
                      "width": ["type": ["number", "null"]], "height": ["type": ["number", "null"]]]),
            function("move_handwriting",
                     "Move some of the student's handwriting (words by id, together as a block) so its top-left corner is at (x, y). Use it to tidy and organize their notes. Undo puts it back.",
                     ["page": page, "pdf_page": pdfPage,
                      "ids": ["type": "array", "items": ["type": "string"], "description": "Handwritten word ids, like h12."],
                      "x": number, "y": number]),
            function("show_area",
                     "Scroll and zoom the page so an area fills the screen, to show them something. All four null to fit everything on the page (on a PDF, go to the page).",
                     ["page": page, "pdf_page": pdfPage,
                      "x": ["type": ["number", "null"]], "y": ["type": ["number", "null"]],
                      "width": ["type": ["number", "null"]], "height": ["type": ["number", "null"]]]),
            function("undo",
                     "Undo the last change on a page, theirs or yours, like the Undo button.",
                     ["page": page]),
            function("redo",
                     "Redo what was last undone on a page.",
                     ["page": page]),
            function("remove_highlight",
                     "Remove highlights on a PDF page whose text contains the given text.",
                     ["page": page, "pdf_page": pdfPage, "text": text("Text in the highlight to remove.")]),
            function("write_by_hand",
                     "Write on the page by hand, as ink in a handwriting style: a word, a definition, a short answer, a label. Keep it short (a few words to a few lines). Use it to add to handwritten notes. Leave x and y null to write beside what they circled, or in free space in view.",
                     ["page": page, "pdf_page": pdfPage, "text": text("What to write. Use \\n for a new line."), "x": x, "y": y,
                      "letter_height": ["type": ["number", "null"], "description": "Height of a capital letter, in page points. Null to match their handwriting."],
                      "bold": ["type": "boolean", "description": "Thicker, bolder ink that's easier to read. Use it when they find your writing thin or hard to read (and remember that they like it bold), or for a heading."],
                      "color": color]),
            function("add_note",
                     "Add a typed note to the page, in the page's own text style. For longer text, or where their notes are typed. Plain text with simple line breaks.",
                     ["page": page, "pdf_page": pdfPage, "text": text("The note."), "x": x, "y": y, "color": color]),
            function("mark",
                     "Draw a hand-drawn mark on the page, in ink: circle, underline, double_underline, box or strike around an area; check or cross beside it; bracket on its left; or an arrow from the area to a point (to_x, to_y). Use it to point at things, like a mistake (red) or what's right (green).",
                     ["page": page, "pdf_page": pdfPage,
                      "kind": ["type": "string", "enum": ["circle", "underline", "double_underline", "box", "strike", "arrow", "check", "cross", "bracket"]],
                      "x": number, "y": number, "width": number, "height": number,
                      "to_x": ["type": ["number", "null"], "description": "Where an arrow points, in page points. Null otherwise."],
                      "to_y": ["type": ["number", "null"]],
                      "color": color]),
            function("draw",
                     "Draw by hand on the page, in ink: a diagram, a graph, a sketch or a simple picture (a cell, a circuit, a triangle with its angles, boxes joined by arrows, a little plant). Give a box on the page to draw in, and the strokes inside it in the box's own coordinates: its longer side runs from 0 to 100 and the other side in proportion (a box 300 wide and 150 tall runs x 0–100, y 0–50), with y growing down. Each stroke is one pen line, as pen commands: M x y moves the pen, L x y draws a straight line, H x and V y go straight across or down to there, Q cx cy x y and C c1x c1y c2x c2y x y draw curves, A cx cy rx ry start sweep draws part of an ellipse (in degrees, 0 at the right and 90 at the bottom; on its own, A cx cy rx ry 0 360 is a whole ellipse), Z closes the shape. Or give just numbers, x y x y …, for a smooth freehand line through those points. Keep it simple and clear, like a good student's sketch. Then label it with write_by_hand (the result says where the drawing's points are on the page), and look_at it to check.",
                     ["page": page, "pdf_page": pdfPage,
                      "x": ["type": ["number", "null"], "description": "Left edge of the box, in page points. Null to let Memor find a free spot beside what they circled, or in view."],
                      "y": ["type": ["number", "null"], "description": "Top edge of the box, in page points. Null together with x."],
                      "width": ["type": "number", "description": "Width of the box, in page points."],
                      "height": ["type": "number", "description": "Height of the box, in page points."],
                      "strokes": ["type": "array", "items": ["type": "string"], "description": "The pen lines, in the order you'd draw them, like \"M 10 40 L 90 40\", \"A 50 25 20 20 0 360\" or \"10 30 30 10 50 30 70 10\"."],
                      "pen_width": ["type": ["number", "null"], "description": "How thick the pen is, in page points. Null to match their pen."],
                      "color": color]),
            function("move_item",
                     "Move a typed note or picture so its top-left corner is at (x, y), in page points.",
                     ["page": page, "id": id, "x": number, "y": number]),
            function("resize_item",
                     "Change the width of a typed note or picture, in page points. Pictures keep their shape; notes rewrap.",
                     ["page": page, "id": id, "width": number]),
            function("edit_text",
                     "Replace all the text of a typed note, to fix, rewrite, shorten or translate it. It keeps its color; to change the color, use recolor.",
                     ["page": page, "id": id, "text": text("The note's new text, in full.")]),
            function("recolor",
                     "Change the color of things on a page: typed notes by their ids (from get_page_items, or from when you added them), handwritten words by their ids (h12, from look_at with label_handwriting or get_page_items), or all the writing inside an area (x, y, width, height). Works on their notes and writing and on what you added, wrote or drew. Undo puts the old color back.",
                     ["page": page, "pdf_page": pdfPage,
                      "ids": ["type": "array", "items": ["type": "string"], "description": "Typed note ids and/or handwritten word ids. Empty to color everything written inside the area."],
                      "x": ["type": ["number", "null"]], "y": ["type": ["number", "null"]],
                      "width": ["type": ["number", "null"]], "height": ["type": ["number", "null"]],
                      "color": ["type": "string", "description": "red, green, blue, orange, purple, pink, black or gray, or #RRGGBB."]]),
            function("delete_item",
                     "Delete a typed note or picture. Only when they ask you to remove something.",
                     ["page": page, "id": id]),
            function("highlight_text",
                     "Highlight text on a PDF page. Give the exact text as it appears on the page.",
                     ["page": page, "pdf_page": pdfPage, "text": text("The exact text to highlight."),
                      "color": ["type": "string", "enum": ["yellow", "green", "blue", "pink"]]]),
            function("read_pages",
                     "Read the text of a PDF's pages, up to 10 at a time.",
                     ["page": page, "from": ["type": "integer", "description": "First page, from 1."], "to": ["type": "integer", "description": "Last page."]]),
            function("search_notes",
                     "Search all their notebooks and PDFs (titles, page titles, typed notes and PDF text; not handwriting) for a word or topic. Returns where it comes up.",
                     ["query": text("What to look for.")]),
            function("offer_choices",
                     "Show them a few options on screen and wait for their pick. Only when they ask to see options or to choose (\"show me some pictures to pick from\"); otherwise choose yourself. For pictures, give each a direct https link to an image file. Returns their pick, or what they said instead.",
                     ["question": text("A short question shown above the options."),
                      "options": [
                        "type": "array",
                        "description": "Two to six options.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": text("A short label."),
                                "image_url": ["type": ["string", "null"], "description": "A direct https link to a picture for this option, or null."],
                            ] as [String: Any],
                            "required": ["label", "image_url"],
                            "additionalProperties": false,
                        ] as [String: Any],
                      ] as [String: Any]]),
            function("set_reminder",
                     "Remind them later with a notification, even if Memor is closed: to come back from a break, to review something, before an exam.",
                     ["minutes": ["type": "number", "description": "How many minutes from now."],
                      "message": text("What the notification says, in your voice, short.")]),
            function("remember",
                     "Remember something for later talks: about the student, about how they like you to be, or about the notebook or PDF it concerns.",
                     ["text": text("One short sentence in the third person."),
                      "about": ["type": "string", "enum": ["student", "style", "page"]],
                      "page": page]),
            function("recall",
                     "Look up earlier talks and what you remember about their notebooks and PDFs.",
                     ["query": text("What to look for, in a few words.")]),
            function("clip_from_pdf",
                     "Copy an area of a PDF page onto a notebook page as an exact picture: an exam question, a diagram, a table, a formula. Use it instead of redrawing or retyping what's on a PDF; it's exact and quick. The area is in the PDF page's points from its top-left, as look_at and get_page_items on the PDF give them: look at the page first and frame the area closely. It copies the PDF itself, not their ink or notes on it. The PDF doesn't have to be open.",
                     ["pdf": ["type": ["string", "null"], "description": "The PDF: its open page's name (P1) or its item_id. Null for the open PDF."],
                      "pdf_page": ["type": "integer", "description": "Which page of the PDF, from 1."],
                      "x": ["type": "number", "description": "Left edge of the area, in the PDF page's points."],
                      "y": ["type": "number", "description": "Top edge of the area."],
                      "width": ["type": "number", "description": "Width of the area."],
                      "height": ["type": "number", "description": "Height of the area."],
                      "page": ["type": ["string", "null"], "description": "The notebook page to put it on: N1 and so on. Null for the open notebook page."],
                      "to_x": ["type": ["number", "null"], "description": "Left edge on the notebook page, in its points. Null to let Memor find a free spot beside what they circled, or in view."],
                      "to_y": ["type": ["number", "null"], "description": "Top edge on the notebook page. Null together with to_x."],
                      "to_width": ["type": ["number", "null"], "description": "Width on the notebook page; the height follows. Null for the same size as on the PDF."]]),
        ]
        tools += PalAppTools.definitions()
        if canDraw {
            let pictureWidth: [String: Any] = ["type": ["number", "null"], "description": "Width on the page, in page points; the height follows the picture's shape. Null for the usual size (at most 400 points a side)."]
            tools.append(function("add_image_from_web",
                                  "Put a picture from the web on a notebook page: at x and y, or beside what they circled or in view. Find a direct https link to an image file first (Wikimedia Commons is good). If it fails, try another link.",
                                  ["page": page, "image_url": text("Direct https link to the image file."), "description": text("What it shows."),
                                   "x": x, "y": y, "width": pictureWidth]))
            tools.append(function("draw_picture",
                                  "Draw a new picture with an image model and put it on a notebook page: at x and y, or beside what they circled or in view. Write a detailed prompt: subject, style, colors, and any labels spelled out exactly (few and short). For diagrams that sit on their notes, ask for a clean, simple style with a transparent background; the see-through margin is trimmed, so the picture's frame is what's drawn. Not for anything on a PDF (use clip_from_pdf). Takes up to a minute.",
                                  ["page": page, "prompt": text("What to draw, in detail."), "description": text("A short description."),
                                   "transparent_background": ["type": "boolean"],
                                   "x": x, "y": y, "width": pictureWidth]))
        }
        return tools
    }

    static func function(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": properties.keys.sorted(),
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    /// What she's doing while a tool runs, for the line over her head and
    /// her chat card.
    static func status(for name: String) -> PalActivity? {
        switch name {
        case "web_search": PalActivity(text: "Searching the web…", symbol: "globe")
        case "web_fetch": PalActivity(text: "Reading a web page…", symbol: "safari")
        case "look_at": PalActivity(text: "Looking closely…", symbol: "eye")
        case "get_page_items": PalActivity(text: "Looking at your page…", symbol: "doc.text.magnifyingglass")
        case "erase_handwriting": PalActivity(text: "Erasing…", symbol: "eraser")
        case "move_handwriting": PalActivity(text: "Tidying your page…", symbol: "arrow.up.and.down.and.arrow.left.and.right")
        case "show_area", "go_to_page", "open_item": PalActivity(text: "Showing you…", symbol: "eye")
        case "close_item": PalActivity(text: "Closing…", symbol: "xmark.square")
        case "clip_from_pdf": PalActivity(text: "Copying from the PDF…", symbol: "scissors")
        case "undo": PalActivity(text: "Undoing…", symbol: "arrow.uturn.backward")
        case "redo": PalActivity(text: "Redoing…", symbol: "arrow.uturn.forward")
        case "remove_highlight": PalActivity(text: "Removing a highlight…", symbol: "highlighter")
        case "list_library", "list_pages": PalActivity(text: "Looking at your library…", symbol: "books.vertical")
        case "create_notebook": PalActivity(text: "Making a notebook…", symbol: "book.closed")
        case "add_page": PalActivity(text: "Adding a page…", symbol: "doc.badge.plus")
        case "rename_item", "rename_page": PalActivity(text: "Renaming…", symbol: "character.cursor.ibeam")
        case "move_page": PalActivity(text: "Moving a page…", symbol: "arrow.up.arrow.down")
        case "delete_page", "delete_from_library": PalActivity(text: "Waiting for you to confirm…", symbol: "hand.raised")
        case "set_my_name": PalActivity(text: "Trying on my new name…", symbol: "heart")
        case "write_by_hand": PalActivity(text: "Writing on your page…", symbol: "pencil.and.scribble")
        case "add_note": PalActivity(text: "Adding a note…", symbol: "note.text")
        case "mark": PalActivity(text: "Marking your page…", symbol: "scribble")
        case "draw": PalActivity(text: "Drawing on your page…", symbol: "pencil.and.outline")
        case "move_item", "resize_item": PalActivity(text: "Moving things around…", symbol: "arrow.up.and.down.and.arrow.left.and.right")
        case "edit_text": PalActivity(text: "Editing a note…", symbol: "pencil")
        case "recolor": PalActivity(text: "Changing the color…", symbol: "paintpalette")
        case "delete_item": PalActivity(text: "Removing something…", symbol: "trash")
        case "highlight_text": PalActivity(text: "Highlighting…", symbol: "highlighter")
        case "read_pages": PalActivity(text: "Reading…", symbol: "book")
        case "search_notes": PalActivity(text: "Looking through your notes…", symbol: "magnifyingglass")
        case "offer_choices": PalActivity(text: "Waiting for you to choose…", symbol: "hand.tap")
        case "set_reminder": PalActivity(text: "Setting a reminder…", symbol: "bell")
        case "remember": PalActivity(text: "Remembering that…", symbol: "brain")
        case "recall": PalActivity(text: "Thinking back…", symbol: "clock.arrow.circlepath")
        case "add_image_from_web": PalActivity(text: "Finding a picture…", symbol: "photo.on.rectangle")
        case "draw_picture": PalActivity(text: "Creating an image…", symbol: "photo")
        default: nil
        }
    }

    // MARK: Running

    static func run(name: String, arguments: String, context: Context) async -> Outcome {
        guard let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] else {
            return .text("The arguments weren't valid JSON.", isError: true)
        }
        if let outcome = await PalAppTools.run(name: name, input: input, context: context) {
            // What she did in the library, like opening a notebook.
            if !outcome.isError, !["list_library", "list_pages"].contains(name), let text = outcome.output as? String {
                PalRecentActions.shared.record(text)
            }
            return outcome
        }
        switch name {
        case "search_notes":
            return .text(await PalLibrary.search(string(input["query"]) ?? ""))
        case "offer_choices":
            return await offerChoices(input, context: context)
        case "set_reminder":
            return await PalReminders.schedule(minutes: number(input["minutes"]) ?? 0, message: string(input["message"]) ?? "")
        case "remember":
            return remember(input)
        case "recall":
            let found = PalMemoryStore.shared.recall(string(input["query"]) ?? "")
            return .text(found.isEmpty ? "Nothing about that in what you remember." : found.joined(separator: "\n"))
        case "add_image_from_web":
            return await addImage(input, context: context)
        case "draw_picture":
            return await drawPicture(input, context: context)
        case "clip_from_pdf":
            return await clipFromPDF(input, context: context)
        default:
            break
        }

        guard let page = pageWithItems(name, input) ?? openPage(for: input) else {
            return .text(input["page"] is String ? "No open page is called that. The open pages are listed with their names at the top of the message." : "No notebook page or PDF is open right now.", isError: true)
        }
        let place = placement(for: input, on: page, circle: context.circle)
        let outcome = runOnPage(name, input, page: page, place: place)
        record(name, input, outcome, on: page, pageIndex: place.pageIndex)
        return outcome
    }

    /// A tool that works on one open page.
    private static func runOnPage(_ name: String, _ input: [String: Any], page: PalPage, place: PalPlace) -> Outcome {
        switch name {
        case "look_at":
            return look(at: input, on: page, in: place)

        case "erase_handwriting":
            let ids = (input["ids"] as? [Any] ?? []).compactMap { $0 as? String }
            let region = area(input)
            guard !ids.isEmpty || region != nil else { return .text("Give word ids, or an area.", isError: true) }
            let erased = page.palEraseHandwriting(ids: ids, region: region, pageIndex: place.pageIndex)
            return .text(erased.result, isError: erased.isError, changedPage: !erased.isError)

        case "move_handwriting":
            let ids = (input["ids"] as? [Any] ?? []).compactMap { $0 as? String }
            guard !ids.isEmpty, let origin = point(input["x"], input["y"]) else {
                return .text("Give word ids, and x and y for where they go.", isError: true)
            }
            let moved = page.palMoveHandwriting(ids: ids, to: origin, pageIndex: place.pageIndex)
            return .text(moved.result, isError: moved.isError, changedPage: !moved.isError)

        case "show_area":
            return page.palShowArea(area(input), pageIndex: place.pageIndex).map { Outcome.text($0, isError: true) } ?? .text("Showing it.")

        case "undo":
            return page.palUndo() ? .text("Undid the last change.", changedPage: true) : .text("There's nothing to undo.", isError: true)

        case "redo":
            return page.palRedo() ? .text("Redid it.", changedPage: true) : .text("There's nothing to redo.", isError: true)

        case "remove_highlight":
            return changed(page.palRemoveHighlights(string(input["text"]) ?? "", pageIndex: place.pageIndex), "Removed the highlight.")

        case "get_page_items":
            var description = page.palItems(pageIndex: place.pageIndex)
            if let near = place.near {
                description += "\n\nThey circled the area x \(Int(near.minX)), y \(Int(near.minY)), width \(Int(near.width)), height \(Int(near.height))."
            }
            return .text(description)

        case "write_by_hand":
            guard let text = string(input["text"]), !text.isEmpty else { return .text("`text` must be a non-empty string.", isError: true) }
            let written = page.palWrite(
                text,
                at: point(input["x"], input["y"]),
                letterHeight: number(input["letter_height"]).map { CGFloat($0) },
                bold: input["bold"] as? Bool ?? false,
                color: PalColor.parse(string(input["color"])),
                in: place
            )
            return .text(written.result, isError: written.isError, changedPage: !written.isError)

        case "add_note":
            guard let text = string(input["text"]), !text.isEmpty else { return .text("`text` must be a non-empty string.", isError: true) }
            guard let id = page.palAddText(text, at: point(input["x"], input["y"]), color: PalColor.parse(string(input["color"])), in: place) else {
                return .text("Couldn't add the note there. The page has to be on screen.", isError: true)
            }
            return .text("Added a typed note with id \(id.uuidString).", changedPage: true)

        case "mark":
            guard let kind = mark(string(input["kind"])),
                  let x = number(input["x"]), let y = number(input["y"]),
                  let width = number(input["width"]), let height = number(input["height"]) else {
                return .text("`kind` must be one of the marks, and x, y, width and height numbers.", isError: true)
            }
            let rect = CGRect(x: x, y: y, width: max(width, 1), height: max(height, 1))
            let problem = page.palMark(kind, around: rect, to: point(input["to_x"], input["to_y"]), color: PalColor.parse(string(input["color"])), in: place)
            return problem.map { Outcome.text($0, isError: true) } ?? Outcome.text("Marked it.", changedPage: true)

        case "draw":
            let strokes = (input["strokes"] as? [Any] ?? []).compactMap { string($0) }.filter { !$0.isEmpty }
            guard !strokes.isEmpty else { return .text("`strokes` must list at least one pen line.", isError: true) }
            guard let width = number(input["width"]), let height = number(input["height"]), width > 0, height > 0 else {
                return .text("width and height must give the size of the box to draw in, in page points.", isError: true)
            }
            let size = CGSize(width: min(width, 2_000), height: min(height, 2_000))
            let penWidth = number(input["pen_width"]).map { CGFloat(min(max($0, 0.5), 20)) }
            let drawn = page.palDraw(strokes, at: point(input["x"], input["y"]), size: size, color: PalColor.parse(string(input["color"])), penWidth: penWidth, in: place)
            return .text(drawn.result, isError: drawn.isError, changedPage: !drawn.isError)

        case "move_item":
            guard let id = itemID(input), let origin = point(input["x"], input["y"]) else {
                return .text("`id` must be an item id, and x and y numbers.", isError: true)
            }
            return changed(page.palMoveItem(id, to: origin), "Moved it.")

        case "resize_item":
            guard let id = itemID(input), let width = number(input["width"]), width > 0 else {
                return .text("`id` must be an item id, and `width` a positive number.", isError: true)
            }
            return changed(page.palResizeItem(id, width: width), "Resized it.")

        case "edit_text":
            guard let id = itemID(input), let text = string(input["text"]), !text.isEmpty else {
                return .text("`id` must be a typed note's id, and `text` a non-empty string.", isError: true)
            }
            return changed(page.palEditText(id, text: text), "Replaced the text.")

        case "delete_item":
            guard let id = itemID(input) else { return .text("`id` must be an item id.", isError: true) }
            return changed(page.palDeleteItem(id), "Deleted it. They can undo this.")

        case "recolor":
            guard let color = PalColor.parse(string(input["color"])) else {
                return .text("`color` must be red, green, blue, orange, purple, pink, black, gray or #RRGGBB.", isError: true)
            }
            let (notes, ink) = splitIDs(input)
            let region = area(input)
            guard !notes.isEmpty || !ink.isEmpty || region != nil else {
                return .text("Give ids, or an area (x, y, width and height).", isError: true)
            }
            let recolored = page.palRecolor(notes: notes, ink: ink, region: region, color: color, pageIndex: place.pageIndex)
            return .text(recolored.result, isError: recolored.isError, changedPage: !recolored.isError)

        case "highlight_text":
            guard let text = string(input["text"]), !text.isEmpty else { return .text("`text` must be the text to highlight.", isError: true) }
            let color = HighlightColor(rawValue: string(input["color"]) ?? "") ?? .yellow
            return changed(page.palHighlight(text, pageIndex: place.pageIndex, color: color), "Highlighted it.")

        case "read_pages":
            let from = max(Int(number(input["from"]) ?? 1), 1)
            let to = min(max(Int(number(input["to"]) ?? Double(from)), from), from + 9)
            guard let text = page.palReadPages((from - 1)...(to - 1)) else {
                return .text("That page is a notebook page, not a PDF.", isError: true)
            }
            return .text(text)

        default:
            return .text("There's no tool called \(name).", isError: true)
        }
    }

    // MARK: Tools

    /// An area from x, y, width and height, if all four are given.
    private static func area(_ input: [String: Any]) -> CGRect? {
        guard let x = number(input["x"]), let y = number(input["y"]),
              let width = number(input["width"]), let height = number(input["height"]) else { return nil }
        return CGRect(x: x, y: y, width: max(width, 8), height: max(height, 8))
    }

    private static func look(at input: [String: Any], on page: PalPage, in place: PalPlace) -> Outcome {
        let labels = input["label_handwriting"] as? Bool ?? false
        guard let look = page.palLook(at: area(input), pageIndex: place.pageIndex, labelHandwriting: labels) else {
            return .text("There's nothing there to see.", isError: true)
        }
        let shown = look.area
        let note = "\(PalWorkspace.shared.shortID(of: page)): this shows page points x \(Int(shown.minX))–\(Int(shown.maxX)), y \(Int(shown.minY))–\(Int(shown.maxY))."
        return Outcome(output: [
            ["type": "input_text", "text": note],
            ["type": "input_image", "image_url": "data:image/jpeg;base64," + look.image.base64EncodedString(), "detail": "high"],
        ] as [[String: Any]])
    }

    private static func offerChoices(_ input: [String: Any], context: Context) async -> Outcome {
        let question = string(input["question"]) ?? ""
        let options = (input["options"] as? [[String: Any]] ?? []).enumerated().compactMap { index, option -> PalChoice.Option? in
            guard let label = string(option["label"]), !label.isEmpty else { return nil }
            let url = string(option["image_url"]).flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
            return PalChoice.Option(id: index, label: label, imageURL: url)
        }
        guard options.count >= 2 else { return .text("Give at least two options.", isError: true) }
        return .text(await context.offerChoices(question, options))
    }

    private static func remember(_ input: [String: Any]) -> Outcome {
        guard PalMemoryStore.isOn else { return .text("Remembering is turned off in Settings, so you can't keep this.", isError: true) }
        guard let text = string(input["text"]), !text.isEmpty else { return .text("`text` must be a sentence.", isError: true) }
        switch string(input["about"]) {
        case "page":
            guard let page = openPage(for: input) else { return .text("No notebook or PDF is open to remember it with.", isError: true) }
            PalMemoryStore.shared.remember(text, kind: .about, itemID: page.palItemID, itemTitle: page.palItemTitle)
        case "style":
            PalMemoryStore.shared.remember(text, kind: .style, itemID: nil, itemTitle: nil)
        default:
            PalMemoryStore.shared.remember(text, kind: .about, itemID: nil, itemTitle: nil)
        }
        return .text("Remembered.")
    }

    private static func addImage(_ input: [String: Any], context: Context) async -> Outcome {
        guard let target = openPage(for: input), target.canAddImages else { return .text("Pictures can only go on notebook pages.", isError: true) }
        guard let link = string(input["image_url"]), let url = URL(string: link) else { return .text("`image_url` must be a link.", isError: true) }
        let pageID = target.palPageID
        let place = placement(for: input, on: target, circle: context.circle)
        do {
            let data = try await ImageDownloader.fetch(url)
            let prepared = await Task.detached(priority: .userInitiated) { ImageImport.prepare(data, trimmingClearEdges: true) }.value
            guard let prepared else { return .text("That link isn't an image Memor can read. Try another.", isError: true) }
            // The page may have closed while it downloaded.
            guard let page = PalWorkspace.shared.page(id: pageID),
                  let added = page.palAddImage(prepared, at: point(input["x"], input["y"]), width: number(input["width"]).map { CGFloat($0) }, in: place) else {
                return .text("Couldn't add the picture. The page may have closed.", isError: true)
            }
            let outcome = Outcome.text("Added a picture with id \(added.id.uuidString) at \(describe(added.frame)).", changedPage: true)
            record("add_image_from_web", input, outcome, on: page, pageIndex: nil)
            return outcome
        } catch {
            return .text("\(error.localizedDescription) Try another link.", isError: true)
        }
    }

    private static func drawPicture(_ input: [String: Any], context: Context) async -> Outcome {
        guard let target = openPage(for: input), target.canAddImages else { return .text("Pictures can only go on notebook pages.", isError: true) }
        guard let prompt = string(input["prompt"]), !prompt.isEmpty else { return .text("`prompt` must say what to draw.", isError: true) }
        let pageID = target.palPageID
        let place = placement(for: input, on: target, circle: context.circle)
        do {
            let data = try await OpenAIClient.generateImage(prompt: prompt, transparent: input["transparent_background"] as? Bool ?? false)
            let prepared = await Task.detached(priority: .userInitiated) { ImageImport.prepare(data, trimmingClearEdges: true) }.value
            guard let prepared else { return .text("The picture came back in a form Memor can't read. Try again.", isError: true) }
            guard let page = PalWorkspace.shared.page(id: pageID),
                  let added = page.palAddImage(prepared, at: point(input["x"], input["y"]), width: number(input["width"]).map { CGFloat($0) }, in: place) else {
                return .text("Couldn't add the picture. The page may have closed.", isError: true)
            }
            let outcome = Outcome.text("Drew a picture and added it with id \(added.id.uuidString) at \(describe(added.frame)).", changedPage: true)
            record("draw_picture", input, outcome, on: page, pageIndex: nil)
            return outcome
        } catch is CancellationError {
            return .text("Stopped.", isError: true)
        } catch {
            return .text("Couldn't draw it: \(error.localizedDescription)", isError: true)
        }
    }

    /// Copies an area of a PDF page onto a notebook page, as an exact
    /// picture of it.
    private static func clipFromPDF(_ input: [String: Any], context: Context) async -> Outcome {
        guard let target = notebookPage(for: input) else {
            return .text(input["page"] is String ? "That isn't an open notebook page. Clips go on notebook pages." : "No notebook page is open to put it on. Open one first (open_item).", isError: true)
        }
        guard let source = pdfSource(input["pdf"]) else {
            return .text(input["pdf"] is String ? "No PDF has that name or item_id. The open ones are at the top of the message; list_library has the rest." : "No PDF is open. Give its item_id (from list_library).", isError: true)
        }
        guard let pageNumber = number(input["pdf_page"]).map({ Int($0) }), pageNumber >= 1 else {
            return .text("`pdf_page` must be a page number from 1.", isError: true)
        }
        guard let x = number(input["x"]), let y = number(input["y"]),
              let width = number(input["width"]), let height = number(input["height"]), width > 0, height > 0 else {
            return .text("x, y, width and height must give the area on the PDF page.", isError: true)
        }
        let region = CGRect(x: x, y: y, width: width, height: height)
        let pageID = target.palPageID
        let place = placement(for: input, on: target, circle: context.circle)
        let rendered = await Task.detached(priority: .userInitiated) {
            renderClip(of: PDFFiles.localURL(id: source.id, fileName: source.fileName), pageIndex: pageNumber - 1, area: region)
        }.value
        let clip: (image: PreparedImage, area: CGRect)
        switch rendered {
        case .success(let made): clip = made
        case .failure(let problem): return .text(problem.message, isError: true)
        }
        let placedWidth = number(input["to_width"]).map { CGFloat($0) } ?? clip.area.width
        guard let page = PalWorkspace.shared.page(id: pageID),
              let added = page.palAddImage(clip.image, at: point(input["to_x"], input["to_y"]), width: placedWidth, in: place) else {
            return .text("Couldn't add the clip. The notebook page may have closed.", isError: true)
        }
        let what = "page \(pageNumber) of “\(source.title)”, area \(describe(clip.area))"
        let outcome = Outcome.text("Copied \(what) onto \(PalWorkspace.shared.shortID(of: page)) as a picture with id \(added.id.uuidString) at \(describe(added.frame)).", changedPage: true)
        record("clip_from_pdf", ["description": what, "x": added.frame.minX, "y": added.frame.minY], outcome, on: page, pageIndex: nil)
        return outcome
    }

    /// Why a tool couldn't do something, for her.
    private nonisolated struct Problem: Error {
        let message: String
    }

    /// An area of a PDF page (page points from its top-left), drawn sharp
    /// enough to read when zoomed in, at most 2048 pixels a side. Just the
    /// PDF: no ink, notes or highlights. Blocking: call it off the main
    /// thread. Also returns the area it shows, kept to the page.
    private nonisolated static func renderClip(of url: URL?, pageIndex: Int, area: CGRect) -> Result<(image: PreparedImage, area: CGRect), Problem> {
        guard let url, let document = PDFDocument(url: url) else {
            return .failure(Problem(message: "That PDF's file isn't on this iPad yet, so it can't be copied from."))
        }
        guard !document.isLocked else { return .failure(Problem(message: "That PDF is locked with a password.")) }
        guard let page = document.page(at: pageIndex) else {
            return .failure(Problem(message: "That PDF has only \(document.pageCount) pages."))
        }
        let box = page.bounds(for: .cropBox)
        let clip = area.intersection(CGRect(origin: .zero, size: box.size))
        guard !clip.isNull, clip.width >= 4, clip.height >= 4 else {
            return .failure(Problem(message: "That area isn't on the page: page \(pageIndex + 1) is \(Int(box.width)) × \(Int(box.height)) points."))
        }
        let scale = min(4, CGFloat(ImageImport.maxPixelSize) / max(clip.width, clip.height))
        let pixelWidth = max(Int((clip.width * scale).rounded()), 1)
        let pixelHeight = max(Int((clip.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return .failure(Problem(message: "Couldn't copy that area.")) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // PDF space has y growing up, from the bottom of the page.
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -clip.minX, y: -(box.height - clip.maxY))
        page.draw(with: .cropBox, to: context)
        // PNG, so text keeps crisp edges.
        guard let image = context.makeImage(), let prepared = ImageImport.encode(image, hasAlpha: false, lossless: true) else {
            return .failure(Problem(message: "Couldn't copy that area."))
        }
        return .success((prepared, clip))
    }

    /// A notebook page for a clip: the one named, or the open one (the one
    /// they're using first).
    private static func notebookPage(for input: [String: Any]) -> PalPage? {
        if let name = string(input["page"]), !name.isEmpty {
            return PalWorkspace.shared.page(shortID: name).flatMap { $0.canAddImages ? $0 : nil }
        }
        let workspace = PalWorkspace.shared
        return (workspace.visiblePages + workspace.openPages).first { $0.canAddImages }
    }

    /// The PDF to copy from: named by its open page's name (P1) or its
    /// item_id, or the open one.
    private static func pdfSource(_ value: Any?) -> (id: UUID, fileName: String, title: String)? {
        let workspace = PalWorkspace.shared
        let wanted: UUID?
        if let name = string(value), !name.isEmpty {
            if let id = UUID(uuidString: name) {
                wanted = id
            } else if let page = workspace.page(shortID: name), page.palKind == .pdf {
                wanted = page.palItemID
            } else {
                return nil
            }
        } else {
            wanted = (workspace.visiblePages + workspace.openPages).first { $0.palKind == .pdf }?.palItemID
        }
        guard let id = wanted, let context = PalLibrary.container?.mainContext else { return nil }
        var descriptor = FetchDescriptor<PDFItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let pdf = (try? context.fetch(descriptor))?.first else { return nil }
        return (pdf.id, pdf.fileName, pdf.title)
    }

    /// An area, as she reads it.
    private static func describe(_ rect: CGRect) -> String {
        "x \(Int(rect.minX.rounded())), y \(Int(rect.minY.rounded())), width \(Int(rect.width.rounded())), height \(Int(rect.height.rounded()))"
    }

    // MARK: What she did

    /// Keeps a change she made, with where it was, so she can come back to
    /// it later ("make it green").
    private static func record(_ name: String, _ input: [String: Any], _ outcome: Outcome, on page: PalPage, pageIndex: Int?) {
        guard outcome.changedPage, !outcome.isError else { return }
        let kind = page.palKind == .notebook ? "notebook" : "PDF"
        let spot = page.palKind == .pdf ? pageIndex.map { "page \($0 + 1)" } ?? page.palWhere : page.palWhere
        let place = "\(PalWorkspace.shared.shortID(of: page)), \(kind) “\(page.palItemTitle)”, \(spot)"
        var what = [name]
        if let text = string(input["text"]), !text.isEmpty {
            what.append("“\(text.prefix(120))\(text.count > 120 ? "…" : "")”")
        }
        if let description = string(input["description"]), !description.isEmpty {
            what.append("“\(description.prefix(80))”")
        }
        if let mark = string(input["kind"]) { what.append(mark) }
        if let id = string(input["id"]) { what.append("id \(id)") }
        let ids = (input["ids"] as? [Any] ?? []).compactMap { $0 as? String }
        if !ids.isEmpty { what.append("ids \(ids.joined(separator: ", "))") }
        if let region = area(input) {
            what.append("area x \(Int(region.minX)), y \(Int(region.minY)), width \(Int(region.width)), height \(Int(region.height))")
        } else if let origin = point(input["x"], input["y"]) {
            what.append("at x \(Int(origin.x)), y \(Int(origin.y))")
        }
        if let color = string(input["color"]), !color.isEmpty { what.append("in \(color)") }
        let result = outcome.output as? String ?? ""
        PalRecentActions.shared.record("\(place): \(what.joined(separator: " ")) → \(result)")
    }

    // MARK: Reading arguments

    /// The page a tool is for: the one named, or the one they're using.
    private static func openPage(for input: [String: Any]) -> PalPage? {
        if let name = string(input["page"]), !name.isEmpty {
            return PalWorkspace.shared.page(shortID: name)
        }
        return PalWorkspace.shared.focusedPage ?? PalWorkspace.shared.visiblePages.first
    }

    /// For tools that change typed notes or pictures by id: the open page
    /// they're on, whatever `page` says, so an id from earlier in the talk
    /// still works. Nil for other tools, or when no open page has them.
    private static func pageWithItems(_ name: String, _ input: [String: Any]) -> PalPage? {
        let ids: [UUID]
        switch name {
        case "move_item", "resize_item", "edit_text", "delete_item": ids = itemID(input).map { [$0] } ?? []
        case "recolor": ids = splitIDs(input).notes
        default: return nil
        }
        guard !ids.isEmpty else { return nil }
        let holds: (PalPage) -> Bool = { page in ids.contains { page.palHasItem($0) } }
        if let named = openPage(for: input), holds(named) { return named }
        return PalWorkspace.shared.openPages.first(where: holds)
    }

    /// `ids` split into typed note and picture ids (UUIDs) and handwritten
    /// word ids (h12).
    private static func splitIDs(_ input: [String: Any]) -> (notes: [UUID], ink: [String]) {
        var notes: [UUID] = []
        var ink: [String] = []
        for case let id as String in input["ids"] as? [Any] ?? [] {
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let uuid = UUID(uuidString: id) { notes.append(uuid) } else if !id.isEmpty { ink.append(id) }
        }
        return (notes, ink)
    }

    /// Which PDF page, and what to put things beside: what they circled,
    /// when it's on this page.
    private static func placement(for input: [String: Any], on page: PalPage, circle: PalCircle?) -> PalPlace {
        let circle = circle?.pageID == page.palPageID ? circle : nil
        var pageIndex = number(input["pdf_page"]).map { Int($0) - 1 }
        if pageIndex == nil { pageIndex = circle?.pageIndex }
        let isSamePage = page.palKind == .notebook || circle?.pageIndex == pageIndex
        return PalPlace(pageIndex: page.palKind == .pdf ? pageIndex : nil, near: isSamePage ? circle?.rect : nil)
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func point(_ x: Any?, _ y: Any?) -> CGPoint? {
        guard let x = number(x), let y = number(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func itemID(_ input: [String: Any]) -> UUID? {
        string(input["id"]).flatMap(UUID.init(uuidString:))
    }

    private static func mark(_ name: String?) -> PalInk.Mark? {
        switch name {
        case "circle": .circle
        case "underline": .underline
        case "double_underline": .doubleUnderline
        case "box": .box
        case "strike": .strike
        case "arrow": .arrow
        case "check": .check
        case "cross": .cross
        case "bracket": .bracket
        default: nil
        }
    }

    private static func changed(_ problem: String?, _ success: String) -> Outcome {
        problem.map { Outcome.text($0, isError: true) } ?? Outcome.text(success, changedPage: true)
    }
}

// MARK: - Colors

/// Ink colors she can name.
enum PalColor {
    private static let names = ["red", "green", "blue", "orange", "purple", "pink", "black", "gray"]

    /// A color as she'd say it: one of hers, or #RRGGBB.
    static func name(_ color: UIColor) -> String {
        let code = hex(color)
        return names.first { parse($0).map(hex) == code } ?? code
    }

    private static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte: (CGFloat) -> Int = { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    static let red = UIColor(red: 0.89, green: 0.22, blue: 0.24, alpha: 1)
    static let green = UIColor(red: 0.13, green: 0.62, blue: 0.33, alpha: 1)

    static func parse(_ name: String?) -> UIColor? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "red": return red
        case "green": return green
        case "blue": return UIColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 1)
        case "orange": return UIColor(red: 0.95, green: 0.52, blue: 0.11, alpha: 1)
        case "purple": return UIColor(red: 0.52, green: 0.30, blue: 0.80, alpha: 1)
        case "pink": return UIColor(red: 0.91, green: 0.36, blue: 0.62, alpha: 1)
        case "black": return .black
        case "gray", "grey": return .gray
        default: break
        }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Searching all your notes

/// Your whole library, for the study pal: what's in it, and searching it.
@MainActor
enum PalLibrary {
    /// Set when the app starts.
    static var container: ModelContainer?

    /// Your notebooks and PDFs by title, most recent first, for when no
    /// page is open.
    static func overview() -> String {
        guard let context = container?.mainContext else { return "" }
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))) ?? []
        let pdfs = (try? context.fetch(FetchDescriptor<PDFItem>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]))) ?? []
        var lines: [String] = []
        if !notebooks.isEmpty {
            lines.append("Notebooks: " + notebooks.prefix(30).map { "“\($0.title)”" }.joined(separator: ", "))
        }
        if !pdfs.isEmpty {
            lines.append("PDFs: " + pdfs.prefix(30).map { "“\($0.title)”" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Where a word or topic comes up: titles, page titles, typed notes and
    /// the text of PDFs. Handwriting isn't searchable.
    static func search(_ query: String) async -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let context = container?.mainContext else { return "Nothing to search for." }
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        func matches(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return lowered.contains(query.lowercased()) || (!words.isEmpty && words.allSatisfy { lowered.contains($0) })
        }
        func snippet(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            guard let range = flat.range(of: words.first ?? query, options: .caseInsensitive) else { return String(flat.prefix(160)) }
            let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
            let end = flat.index(range.upperBound, offsetBy: 100, limitedBy: flat.endIndex) ?? flat.endIndex
            return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
        }

        var found: [String] = []
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        for notebook in notebooks {
            if matches(notebook.title) { found.append("Notebook “\(notebook.title)” (title)") }
            for page in notebook.sortedPages {
                let place = "Notebook “\(notebook.title)”, page “\(page.displayTitle(number: page.number))”"
                if !page.title.isEmpty, matches(page.title) { found.append("\(place) (page title)") }
                for box in page.textBoxes ?? [] where !box.isDeleted && matches(box.plainText) {
                    found.append("\(place), typed note: \(snippet(box.plainText))")
                }
            }
        }
        let pdfs = (try? context.fetch(FetchDescriptor<PDFItem>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]))) ?? []
        var files: [(title: String, id: UUID, fileName: String)] = []
        for pdf in pdfs {
            if matches(pdf.title) { found.append("PDF “\(pdf.title)” (title)") }
            for box in pdf.textBoxes ?? [] where !box.isDeleted && matches(box.plainText) {
                found.append("PDF “\(pdf.title)”, page \((box.pageIndex ?? 0) + 1), their note: \(snippet(box.plainText))")
            }
            if files.count < 40 { files.append((pdf.title, pdf.id, pdf.fileName)) }
        }
        let phrase = words.max { $0.count < $1.count } ?? query
        let inPDFs = await Task.detached(priority: .userInitiated) { searchPDFs(files, for: query, fallback: phrase) }.value
        found += inPDFs

        guard !found.isEmpty else { return "“\(query)” doesn't come up in their titles, typed notes or PDFs. (Handwriting can't be searched.)" }
        return found.prefix(30).joined(separator: "\n") + (found.count > 30 ? "\n…and \(found.count - 30) more." : "")
    }

    /// The text of PDFs, searched away from the main thread.
    private nonisolated static func searchPDFs(_ files: [(title: String, id: UUID, fileName: String)], for query: String, fallback: String) -> [String] {
        var found: [String] = []
        for file in files {
            guard let url = PDFFiles.localURL(id: file.id, fileName: file.fileName),
                  let document = PDFDocument(url: url), !document.isLocked else { continue }
            var hits = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            if hits.isEmpty, fallback != query {
                hits = document.findString(fallback, withOptions: [.caseInsensitive, .diacriticInsensitive])
            }
            for hit in hits.prefix(3) {
                guard let page = hit.pages.first else { continue }
                let line = hit.copy() as? PDFSelection
                line?.extendForLineBoundaries()
                let text = (line?.string ?? hit.string ?? "").replacingOccurrences(of: "\n", with: " ")
                found.append("PDF “\(file.title)”, page \(document.index(for: page) + 1): \(String(text.prefix(200)))")
            }
        }
        return found
    }
}

// MARK: - Reminders

/// Reminders she sets, as notifications, so they come even when Memor is
/// closed.
@MainActor
enum PalReminders {
    static func schedule(minutes: Double, message: String) async -> PalTools.Outcome {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard minutes > 0, minutes <= 60 * 24 * 14, !message.isEmpty else {
            return .text("Give a time from 1 minute to 2 weeks away, and a message.", isError: true)
        }
        let center = UNUserNotificationCenter.current()
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard allowed else {
            return .text("Notifications are off for Memor, so you can't remind them. They can turn them on in Settings › Notifications › Memor.", isError: true)
        }
        let content = UNMutableNotificationContent()
        content.title = StudyPalCharacter.name ?? "Your study pal"
        content.body = message
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, minutes * 60), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        } catch {
            return .text("Couldn't set the reminder.", isError: true)
        }
        let at = Date.now.addingTimeInterval(minutes * 60).formatted(date: .omitted, time: .shortened)
        return .text("Set: a notification at \(at) saying “\(message)”.")
    }
}

/// Shows her reminders even while Memor is open.
final class PalNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = PalNotificationDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

// MARK: - Downloading pictures

/// Downloads a picture she found, carefully: HTTPS only, no cookies or
/// cache, at most 15 MB, and only if the server says it's an image.
enum ImageDownloader {
    private static let maxBytes = 15_000_000

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw OpenAIError.other("Only https image links can be used.")
        }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAIError.other("The image link didn't work.")
        }
        guard (http.mimeType ?? "").hasPrefix("image/") else {
            throw OpenAIError.other("That link isn't an image file.")
        }
        guard data.count <= maxBytes else {
            throw OpenAIError.other("That image is too large.")
        }
        return data
    }
}
