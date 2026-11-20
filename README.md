<p align="center">
  <img src="StudyNotes/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" alt="Memor app icon: a pencil, a crayon and a paintbrush with smiling faces on a yellow notepad">
</p>

<h1 align="center">Memor</h1>

<p align="center">A native iPad app for taking study notes with Apple Pencil and the keyboard.</p>

Memor has two kinds of items:

- **Notebooks** made of pages. Each page is an infinite canvas on dotted paper, where you can write with Apple Pencil and type text anywhere.
- **PDFs** such as lecture slides and readings. You can highlight them, write on them and add typed notes, and Memor reopens each PDF where you stopped reading.

Every notebook and PDF opens in its own window, so you can keep several side by side.

## Features

- **Library:** notebooks on top and PDFs below, both as grids. Import PDFs from the file picker, by dragging them in, or with "Open in Memor" from other apps.
- **Notebook pages:** a grid of pages for each notebook. Add, rename, reorder and delete pages.
- **Infinite canvas:** pinch to zoom from 25% to 400%, pan in every direction, and pick up where you left off. The dots stay lined up with your ink as you zoom.
- **Pencil and text:** the full PencilKit tool picker for ink, plus text boxes you can move and resize. Scribble turns handwriting in a text box into typed text, and typing on a hardware keyboard starts a new box.
- **PDF annotations:** highlight text in four colors with a Pencil swipe or from the text menu, write on pages, and add text notes. Your original PDF files are never modified.
- **Everything stays on your iPad.** No accounts, no tracking, no network.

## Requirements

- iPad with iPadOS 26 or later
- Xcode 26 or later to build

## Building

1. Clone the repo and open `StudyNotes.xcodeproj` in Xcode. (StudyNotes was the working name; the project keeps it.)
2. Select the **StudyNotes** target, open **Signing & Capabilities**, choose your own team, and change the bundle identifier (`com.memor.app`) to one of your own.
3. Pick your iPad as the run destination and press Run.

From the command line:

```bash
xcodebuild -project StudyNotes.xcodeproj -scheme StudyNotes -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## How it's built

- **SwiftUI** for the app, windows, library and toolbars. **UIKit** wrappers around `PKCanvasView` and `PDFView` for the canvas and the reader.
- **SwiftData** for notebooks, pages, highlights, ink and text boxes. The models follow CloudKit's rules (defaults everywhere, optional relationships) so iCloud sync can be added later.
- **PencilKit** for ink, on a 100,000-point canvas per page. A screen-sized view behind the transparent canvas draws the dots, so scrolling stays cheap.
- **PDFKit** with per-page overlay views for ink and text notes. Highlights are stored in the database and drawn as annotations that are never written back to the file.
- **Multiple windows** with `WindowGroup(for:)` and `openWindow`. Open windows come back after a relaunch.

```
StudyNotes/
  App/          app entry point, windows
  Library/      the library grid and its cards
  Notebook/     page grid, page screen, canvas
  PDFReader/    PDF reader, page overlays
  Model/        SwiftData models, file storage
  Shared/       text boxes, dot grid, thumbnails, helpers
Config/         Info.plist and App Store export options
```

## License

The code is released under the [MIT License](LICENSE).
