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
- **Ask Claude:** circle any part of a notebook page or PDF and a glass side panel opens. If you circled a question, Claude answers it; otherwise it explains what's there, and you can ask follow-ups. Uses Claude Opus 5.5 with your own Anthropic API key.
- **Private by default.** No accounts, no analytics, no tracking. Your notes and PDFs stay on your iPad. The only thing that ever leaves it is what you choose to send with Ask Claude: the circled area and your questions go straight to Anthropic, never to a Memor server (there isn't one).

## Your API key

Ask Claude needs an API key from [platform.claude.com](https://platform.claude.com) (a Claude Pro or Max subscription can't be used by other apps). Memor is built so the key can't leak:

- It's stored only in the iPad's Keychain, with `WhenUnlockedThisDeviceOnly`: readable only while the iPad is unlocked, never synced to iCloud, never in backups.
- It's never written to the database, files, `UserDefaults` or logs, and never kept in app state. It's read from the Keychain for each request.
- It's sent only to `api.anthropic.com` over HTTPS (TLS 1.2+), on an ephemeral connection with no cache or cookies. Redirects are refused, so the key header can't be forwarded to another host.
- A new key is checked with a free request before it's saved, and you can remove it any time.

See [`StudyNotes/Ask`](StudyNotes/Ask) for the code.

## Requirements

- iPad with iPadOS 26 or later
- Xcode 26 or later to build

## Building

1. Clone the repo and open `StudyNotes.xcodeproj` in Xcode. (StudyNotes was the working name; the project keeps it.)
2. Select the **StudyNotes** target, open **Signing & Capabilities**, choose your own team, and change the bundle identifier (`com.denasohrabi.memor`) to one of your own.
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
