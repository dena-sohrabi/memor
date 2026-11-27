<p align="center">
  <img src="StudyNotes/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" alt="Memor app icon: a pencil, a crayon and a paintbrush with smiling faces on a yellow notepad">
</p>

<h1 align="center">Memor</h1>

<p align="center">A native iPad app for taking study notes with Apple Pencil and the keyboard.</p>

Memor has two kinds of items:

- **Notebooks** made of pages. Each page is an infinite canvas on dotted paper, where you can write with Apple Pencil and type text anywhere.
- **PDFs** such as lecture slides and readings. You can highlight them, write on them and add typed notes, and Memor reopens each PDF where you stopped reading.

Tap a notebook or PDF in the library and it opens in the same window; Back returns to the library. To see two at once, touch and hold one and choose Open in New Window, then put the windows side by side. Memor reopens whatever you had open, at the page you were on.

## Features

- **Library:** notebooks on top and PDFs below, both as grids. Import PDFs from the file picker, by dragging them in, or with "Open in Memor" from other apps.
- **Notebook pages:** a grid of pages for each notebook. Add, rename, reorder and delete pages.
- **Infinite canvas:** pinch to zoom from 2% to 400%, pan in every direction, and pick up where you left off. The dots stay lined up with your ink as you zoom. The zoom level shows in the top-left corner while you zoom, as in Figma, and fades a moment after you stop: − and + step through it, and the percentage jumps to 100%, fits everything on screen, or goes to 50% or 200%. Tap empty paper with a finger to hide the toolbar, the pen palette and the status bar, and tap again to bring them back.
- **Pencil and text:** the full PencilKit tool picker for ink, plus text boxes you can move and resize. Scribble turns handwriting in a text box into typed text, and typing on a hardware keyboard starts a new box.
- **PDF annotations:** highlight text in four colors with a Pencil swipe or from the text menu, write on pages, and add text notes. Your original PDF files are never modified.
- **Your study pal:** a soft pink creature with gray wings who lives in the whole app, not in one page. There's only ever one of her: she stays on screen as you go from the library to a notebook or a PDF, and sees what's open. Hold her and let go for a small menu that picks Voice or Chat; there are no buttons beside her. She's always there.
- **Live calls:** with your own Memor Live server set up (see [`Server/live-relay`](Server/live-relay)), tapping her in Voice mode calls her through OpenAI's GPT-Live. Just talk: she hears when you've finished and answers right away, and stops when you talk over her. Anything about your pages, and every real question, goes to her mind, which works on your pages as usual, and she says its answer. Tap her again to hang up; she also hangs up after 30 seconds of quiet. A call costs $0.05 a minute while it's open, plus her mind.
- **Voice mode, with no words on screen:** without a Live server, tap her and talk, then tap again to send a voice message (hold her and let go to cancel it). She answers out loud in the voice you pick in Settings, starting with her first words while she writes the rest. Tap her while she talks to hush her. Nothing shows as text: a soft glow means she's listening, and if something goes wrong a small "!" shows over her head (tap it to read what). What you say streams to OpenAI's live transcription model as you say it, with the words on your open pages (a PDF's text, your typed notes, titles) as keywords, so the terms you're studying come out right, and the text is ready the moment you stop.
- **Chat mode:** a compose box sits beside her; tap her to start typing. Send, and her chat card opens with your talk (drag it by its top, and tap her to close it). Her replies are only written, never read aloud.
- **She sees what you see:** every message goes with what's on your screen right then: a picture of the page that's open, its typed text and the PDF's text, what you selected, what you circled, and what she did on your pages lately, so "make it green" still finds what she wrote, even after you've worked on the page yourself. She reads handwriting, and looks closer at any part of a page when something is small or unclear. Circle something with the lasso button and it goes to her right away: circle a word and she tells you what it means here, circle a question and she helps with it, circle your working and she checks it.
- **She works on your pages:** she writes by hand, as real ink at your writing's size and in your pen's color (or bolder, if hers is too thin to read), beside the word you circled; marks your work with circles, underlines, arrows, checks or crosses in a color (to show where a mistake is); adds typed notes and pictures (from the web, or drawn for you, trimmed to what's drawn and placed where she wants them); copies an exam question, diagram or table from a PDF onto a notebook page exactly, as a picture; highlights text in PDFs; erases or moves your own handwriting (she sees each handwritten word with a number, so "remove the Farsi definitions" or "tidy this page" works); moves, resizes, edits or deletes typed notes and pictures; and changes the color of typed notes and of handwriting, yours or hers. What she adds goes in free space beside what it's about, never over your writing, and Undo takes back anything she did. She also searches all your notebooks and PDFs, reads more of a PDF, zooms to show you something, closes a notebook or PDF (or its window) when you're done with it, searches the web, and sets reminders that come as notifications even when Memor is closed ("I need a break" — "I'll call you back in 15 minutes").
- **She runs the app too:** she lists, opens, creates, renames and deletes notebooks and PDFs, and adds, renames, reorders, deletes and goes to pages. Deleting shows you a confirm card first. Ask her to do something and she does it, without follow-up questions.
- **Her mind:** Claude Opus 5.5 with your Anthropic key, or GPT-6.2 Sol with your OpenAI key (switch in Settings). Typed and spoken messages go into one conversation; after half an hour without a message a new one starts.
- **Your study pal's personality:** she's yours to name: the first time you tap her, she asks what you'd like to call her (rename her in Settings, or just tell her). She's warm, curious and a little cheeky, and she grows into the pal you need: she notices how you like to be talked to (more playful or calmer, short or detailed, cheering you on or matter-of-fact) and keeps doing what works.
- **She remembers, in three layers:** what she knows about you and how you like her to be (part of every talk); what she knows about each notebook and PDF, like what it covers and what you found hard (part of a talk only while that one is open); and a line about each talk, which she looks up only when it helps. So she knows what matters without bringing up your other subjects. Settings → Memory shows everything she remembers; delete any of it, forget everything, or turn remembering off.
- **Her little ways:** she waves hello, watches where you write, glances around and blinks, and is delighted when your page changes. Rub her to scratch her: she shuts her eyes, fans her feathers and coos softly, and if you keep scratching, little hearts float up from her. Scratch her with Apple Pencil Pro and you feel each rub in the pencil, like a purr. Press and hold her, or drag her off, to carry her anywhere; she flies after your finger, leaning into the turns. Her little sounds (a pip when she listens, a hum while she thinks, happy chirps, coos) can be turned off in Settings.
- **In your iCloud:** every notebook, page, PDF (the file itself too), highlight, bit of ink, typed note and chat with your study pal is saved to your private iCloud database, along with her memory, her name and your settings. So they're on every iPad signed in to your Apple Account, and they come back if you delete and reinstall Memor. Without iCloud, Memor works the same and syncs once it can. Your API keys never leave the iPad's Keychain.
- **Private by default.** No accounts, no analytics, no tracking. Your notes and PDFs are kept on your iPad and in your own iCloud, never on a Memor server. The only thing that ever leaves it is what you send your study pal: your message (and when you talk to her, your voice, to OpenAI to be turned into text), pictures of the pages on your screen and their text, what you circled or selected, and what she remembers about you and those notes. It goes straight to the company behind her mind (Anthropic or OpenAI), never to a Memor server (there isn't one). What she says goes to OpenAI to be spoken. Your voice goes to OpenAI only while you're talking to her (after you tap her). In a live call it goes through your own Live server, a small relay you run on your own Cloudflare account that passes it to OpenAI without keeping it. Her memory is kept on your iPad and in your iCloud.

## Your API key

The study pal uses your own API keys: one from [platform.claude.com](https://platform.claude.com) for Claude, and one from [platform.openai.com](https://platform.openai.com/api-keys) for her ears and voice, her pictures, and GPT if you pick it. Memor is built so the keys can't leak:

- It's stored only in the iPad's Keychain, with `WhenUnlockedThisDeviceOnly`: readable only while the iPad is unlocked, never synced to iCloud, never in backups.
- It's never written to the database, files, `UserDefaults` or logs, and never kept in app state. It's read from the Keychain for each request.
- Each key is sent only to its own API (`api.anthropic.com` or `api.openai.com`) over HTTPS (TLS 1.2+), on an ephemeral connection with no cache or cookies. Redirects are refused, so the key header can't be forwarded to another host.
- A new key is checked with a free request before it's saved, and you can remove it any time.

What it's used for:

| Job | Model |
|---|---|
| Her mind: every message, with her tools | `claude-opus-5-5` (Messages API), or `gpt-6.2-sol` (Responses API) |
| Writing down what she remembers | `claude-haiku-5-5`, or `gpt-6-luna` |
| Hearing what you say | `gpt-live-transcribe` (Realtime API, transcription), with the words on your pages as keywords |
| Reading her replies aloud | `gpt-realtime-2.1-mini` (Realtime API), in the voice you choose |
| Live calls | `gpt-live-1.1` (Live API, client delegation to her mind), through your Live server |
| Drawing pictures for your page | `gpt-image-2.6-flare` |

OpenAI may ask you to verify your organization before it draws images.

See [`StudyNotes/StudyPal`](StudyNotes/StudyPal) for the code.

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

iCloud sync uses the container `iCloud.com.denasohrabi.memor`, set in [`Config/StudyNotes.entitlements`](Config/StudyNotes.entitlements) and `Persistence.swift`; change both to build under your own team. Debug builds use CloudKit's Development environment, which creates the record types as the app saves. Before a TestFlight or App Store build, deploy the schema to Production in the [CloudKit Console](https://icloud.developer.apple.com), or those builds can't sync.

## How it's built

- **SwiftUI** for the app, library, navigation and toolbars. **UIKit** wrappers around `PKCanvasView` and `PDFView` for the canvas and the reader.
- **SwiftData with CloudKit** for notebooks, pages, images, highlights, ink, text boxes, Ask chats and the PDF files, mirrored to the private database of the `iCloud.com.denasohrabi.memor` container. A PDF's file is in the database with external storage, so it syncs as a CloudKit asset; each iPad also writes a copy to disk for PDFKit, and redraws thumbnails it doesn't have. The models follow CloudKit's rules: defaults everywhere, optional relationships, nothing unique. The study pal's memory and settings sync through iCloud key-value storage.
- **PencilKit** for ink, on a 100,000-point canvas per page. A screen-sized view behind the transparent canvas draws the dots, so scrolling stays cheap.
- **PDFKit** with per-page overlay views for ink and text notes. Highlights are stored in the database and drawn as annotations that are never written back to the file.
- **A main window**, with a `NavigationStack` from the library to the open notebook or PDF (`AppNavigator`), and **a window per notebook or PDF** only when you choose Open in New Window (`ItemWindow`, `WindowGroup(for: OpenTarget.self)`). Each item is in one place at a time: opening one that has its own window brings that window forward. What's open comes back after a relaunch.
- **The study pal** is a glTF model with 14 animation clips, loaded with [GLTFKit2](https://github.com/warrenm/GLTFKit2) and drawn with SceneKit. Shaders tint her coat pink with a velvet sheen, give her wings a pearly edge and keep her surfaces solid. Springs make her lean into her movement, and her sounds are made in code with AVAudioEngine. What you say streams to OpenAI's live transcription over a Realtime WebSocket while you talk (24 kHz PCM); a pause is told from how loud the microphone is next to the room's quiet. Her mind (`PalBrain`) is one conversation for the whole app, with Claude Opus 5.5 (Messages API) or GPT-6.2 Sol (Responses API), streamed, with her tools as function calls; a talk's instructions and tools are fixed when it starts and its history is only ever added to, sent back exactly as it came (thinking included). Each open page registers with `PalWorkspace`, so she can see and work on it; `PalRecentActions` keeps what she did lately, which goes with each message. Her handwriting is real PencilKit ink, drawn from a single-stroke handwriting font with a little natural wobble. Her voice is OpenAI's Realtime API over a WebSocket, reading out what she wrote. Live calls (`PalCall`) are GPT-Live over a WebSocket to the relay in `Server/live-relay` (a Cloudflare Worker that adds the OpenAI key and passes messages through); the microphone and her voice share one AVAudioEngine with voice processing on, so she doesn't hear herself, and GPT-Live hands requests to her mind with client delegation. Her memory is a small JSON file, kept in the app's own storage and in iCloud key-value storage.

```
StudyNotes/
  App/          app entry point, navigation
  Library/      the library grid and its cards
  Notebook/     page grid, page screen, canvas
  PDFReader/    PDF reader, page overlays
  Model/        SwiftData models, file storage
  Shared/       text boxes, dot grid, thumbnails, helpers
  Ask/          the OpenAI client, the API key, circling, settings
  StudyPal/     the study pal: her mind, tools, memory, voice, card and 3D model
Config/         Info.plist, entitlements and App Store export options
```

## License

The code is released under the [MIT License](LICENSE).
