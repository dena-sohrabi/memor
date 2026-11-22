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
- **Infinite canvas:** pinch to zoom from 2% to 400%, pan in every direction, and pick up where you left off. The dots stay lined up with your ink as you zoom. The zoom level shows in the top-left corner while you zoom, as in Figma, and fades a moment after you stop: − and + step through it, and the percentage jumps to 100%, fits everything on screen, or goes to 50% or 200%. Tap empty paper with a finger to hide the toolbar, the pen palette and the status bar, and tap again to bring them back.
- **Pencil and text:** the full PencilKit tool picker for ink, plus text boxes you can move and resize. Scribble turns handwriting in a text box into typed text, and typing on a hardware keyboard starts a new box.
- **PDF annotations:** highlight text in four colors with a Pencil swipe or from the text menu, write on pages, and add text notes. Your original PDF files are never modified.
- **Ask Claude:** circle any part of a notebook page or PDF, ask out loud, or type a question. Claude sees the whole page, answers what you circled and can search the web. It also works on your page like a study pal when you ask: it adds text or images ("find a picture of Gregor Mendel and add it"), and moves, resizes, edits or deletes typed text and images ("line up my definitions on the left"). What Claude adds goes in free space beside what you circled, or near the middle of the screen, without covering your notes, and matches your notes' style, font and color. Your handwriting stays as you wrote it, and Undo takes back anything Claude did. Uses Claude Opus 5.5 with your own Anthropic API key. Each circled question leaves a small marker; tap it to reopen the saved chat in a panel, or hold it to move or delete it.
- **Talk with your study pal:** a soft pink creature with gray wings who sits on your page wherever you put her. With an optional OpenAI key, a switch beside her picks Voice or Chat. **Voice** is like a call: tap her, a soft pip, and she listens (a green glow and a pill under her say whose turn it is). When you pause, she hums while she thinks and answers out loud in the voice you pick in Settings, then listens again. OpenAI's realtime model is the one talking with you, so she answers within about a second; it sees your page and works on it with her tools: writing notes in your style, drawing pictures, and showing options to pick from in a small card (tap one or just tell her). She waits longer when you trail off on "and" or "um". Tap her while she talks to cut in; stay quiet, tap her before you speak, or tap the red button to hang up. **Chat** is for when you can't talk out loud: tap her and the compose box opens, ready to type (its mic button is there if you'd rather say it), and Claude answers in a chat panel you can drag by its top. Without an OpenAI key, it's always Chat.
- **Your study pal's personality:** she's yours to name: the first time you tap her, she asks what you'd like to call her (rename her in Settings, or just tell her). She's warm, curious and a little cheeky, the same pal in Voice and Chat, and she grows into the pal you need: she notices how you like to be talked to (more playful or calmer, short or detailed, cheering you on or matter-of-fact) and keeps doing what works. She knows your page and ties her answers to your notes, and on a call she takes a fresh look whenever you change it.
- **She remembers you:** after each call or chat, she writes down what's worth keeping, like your name, what you study, your exams, what you find hard, how you like her to be and what you talked about, and picks up from it next time ("how did the genetics quiz go?"). Settings → Memory shows everything she remembers; delete any of it, forget everything, or turn remembering off.
- **Her little ways:** she waves hello, watches where you write, glances around and blinks, and is delighted when your page changes. Rub her to scratch her: she shuts her eyes, fans her feathers and coos softly, and if you keep scratching, little hearts float up from her. Scratch her with Apple Pencil Pro and you feel each rub in the pencil, like a purr. Press and hold her, or drag her off, to carry her anywhere; she flies after your finger, leaning into the turns. Her little sounds (a pip when she listens, a hum while she thinks, happy chirps, coos) can be turned off in Settings.
- **Private by default.** No accounts, no analytics, no tracking. Your notes and PDFs stay on your iPad. The only thing that ever leaves it is what you choose to send with Ask Claude: the page you're asking about, what you circled and your questions (as text, even when you ask out loud) go straight to Anthropic, never to a Memor server (there isn't one). If you add an OpenAI key (optional), Voice mode sends what you say (as text), pictures of the page you're on and its typed notes to OpenAI, so she can talk with you about it. Her memory of you is kept on your iPad and goes with each talk to the service you're talking through (Anthropic in Chat, OpenAI in Voice), which also writes down what to remember when the talk ends. Your voice itself never leaves the iPad: speech is recognized on device.

## Your API key

Ask Claude needs an API key from [platform.claude.com](https://platform.claude.com) (a Claude Pro or Max subscription can't be used by other apps). Memor is built so the key can't leak:

- It's stored only in the iPad's Keychain, with `WhenUnlockedThisDeviceOnly`: readable only while the iPad is unlocked, never synced to iCloud, never in backups.
- It's never written to the database, files, `UserDefaults` or logs, and never kept in app state. It's read from the Keychain for each request.
- It's sent only to `api.anthropic.com` over HTTPS (TLS 1.2+), on an ephemeral connection with no cache or cookies. Redirects are refused, so the key header can't be forwarded to another host.
- A new key is checked with a free request before it's saved, and you can remove it any time.

An OpenAI key is optional. With it, Voice mode talks with you through OpenAI's realtime model (`gpt-realtime-2.1-mini`, in the voice you choose), which answers you itself and draws pictures for your page (`gpt-image-2.6-flare`); Chat mode stays with Claude. Her spoken answers cost about 2.4 cents a minute while she talks (OpenAI charges $20 per million audio output tokens; your words go as text, which costs far less). The key gets the same care as the Claude key: Keychain only, sent only to `api.openai.com`, checked before it's saved. OpenAI may ask you to verify your organization before it draws images.

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
- **The study pal** is a glTF model with 14 animation clips, loaded with [GLTFKit2](https://github.com/warrenm/GLTFKit2) and drawn with SceneKit. Shaders tint her coat pink with a velvet sheen, give her wings a pearly edge and keep her surfaces solid. Springs make her lean into her movement, and her sounds are made in code with AVAudioEngine. Speech recognition runs on device with the Speech framework. Her memory is a small JSON file in the app's own storage. In Voice mode she talks through OpenAI's Realtime API over a WebSocket: her answer streams back as audio, and her page tools run as function calls.

```
StudyNotes/
  App/          app entry point, windows
  Library/      the library grid and its cards
  Notebook/     page grid, page screen, canvas
  PDFReader/    PDF reader, page overlays
  Model/        SwiftData models, file storage
  Shared/       text boxes, dot grid, thumbnails, helpers
  Ask/          Ask Claude: API client, chat, panel, settings
  StudyPal/     the study pal model and its animations
Config/         Info.plist and App Store export options
```

## License

The code is released under the [MIT License](LICENSE).
