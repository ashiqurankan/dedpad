# dedpad

*Your notebooks. Your pages. Your way.* A Dedstudio project.

dedpad is a free, native iPad notebook app for handwriting, PDF annotation and custom notebooks.
It's written in Swift with SwiftUI, PencilKit and PDFKit. You can build it and install it on an
iPad **without a Mac**: it builds on Linux with [xtool](https://github.com/xtool-org/xtool).
macOS works too.

## Features

| Area | What you get |
|---|---|
| **Writing** | Apple Pencil and finger input. Ballpoint, fountain pen, monoline, pencil, crayon, watercolour and highlighter, plus whole-stroke and pixel erasers, lasso and ruler. Three colours and three sizes per tool, and saved pens. Palm rejection |
| **Shapes** | Draw a stroke and hold the Pencil still: it snaps to a clean line, triangle, rectangle or circle/ellipse before you lift, and you can keep moving to resize it. There's also a shape tool for lines, arrows, rectangles, ellipses and triangles |
| **Editor** | Continuous vertical scrolling, or sideways page turning like a book. Sharp ink and paper at any zoom, page thumbnails, reordering, and undo and redo. Text boxes, photos and stickers. A typed-notes panel and autosave |
| **Paper** | 26 templates: ruled, dotted, grid, Cornell, planners, storyboards and more. Custom colours, spacing and margins. Save your own templates |
| **Covers** | 20 preset covers, custom colours, patterns, fonts and photo covers |
| **PDF** | Import and annotate PDFs, select and highlight text, search, table of contents, bookmarks. Export with editable annotations |
| **Search** | On-device handwriting recognition. Search covers handwriting, PDF text, typed notes and text boxes |
| **Export** | PDF, PNG, JPEG, SVG, ZIP and JSON archives, TXT and Markdown |
| **Safety** | Offline-first plain files (visible in the Files app). Recently Deleted (30 days). Automatic version history. Damaged-file recovery |
| **Backup** | Optional Google Drive backup to the user's own Drive. Automatic, uploads only what changed, restores on a new iPad |

## Building and installing

### What you need

- An iPad running iPadOS 17 or later, and a USB cable
- An Apple ID (a free one works)
- A Linux machine (tested on Ubuntu 24.04) or a Mac, with about **15 GB free**
- `Xcode.xip` from <https://developer.apple.com/download/all/?q=Xcode>. xtool only takes the iOS SDK from it.

### 1. One-time setup (Linux)

1. **Swift for Linux.** Install the version that the
   [xtool Linux guide](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md)
   asks for, from <https://swift.org/install/linux>.
2. **USB access to the iPad:**
   ```bash
   sudo apt-get install usbmuxd libimobiledevice-utils
   ```
3. **xtool:**
   ```bash
   curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
   chmod +x xtool && sudo mv xtool /usr/local/bin/
   ```
4. **Apple sign-in and the iOS SDK:**
   ```bash
   ./scripts/setup-ipad-sdk.sh /path/to/Xcode.xip
   ```
   Choose **Password** login for a free Apple ID. `swift sdk list` should then show `darwin`.

On macOS, install xtool and follow its macOS guide instead.

> If your system disk is small, you can keep Swift and xtool in a `toolchain/` folder inside the
> project (git ignores it). Add a `toolchain/env.sh` that puts them on `PATH`, and the scripts
> will source it.

### 2. Build and run

Plug the iPad in, unlock it and tap **Trust**. Then:

```bash
./scripts/run-on-ipad.sh        # build, sign, install and launch (same as `xtool dev`)
```

The first time you install:
- On the iPad, turn on **Settings › Privacy & Security › Developer Mode** and restart if asked.
- Trust your certificate under **Settings › General › VPN & Device Management**.
- If xtool stops after the Trust prompt, run the command again.

With a **free Apple ID** the app stops opening after 7 days. Run the script again to re-sign it;
your notebooks are kept.

### 3. Tests

`DedpadCore` holds the models, templates, storage, archives, shape recognition and so on. It is
plain Foundation code, so its tests run on Linux without the iOS SDK:

```bash
./scripts/test-core.sh
```

## Google Drive backup (optional)

Each user backs up to a `dedpad` folder in **their own** Google Drive. There's no server. dedpad
asks only for the `drive.file` permission, so it can see the files it created and nothing else.

Builds work without this. Settings then shows "Google Drive backup isn't set up". To turn it on,
create your own Google sign-in client. It's free:

1. In [Google Cloud Console](https://console.cloud.google.com/projectcreate), create a project.
2. Enable the **Google Drive API** (APIs & Services › Library).
3. Under **Google Auth Platform**, set up:
   - **Branding:** app name and support email.
   - **Audience:** External.
   - **Data access:** add the scopes `openid`, `userinfo.email`, `userinfo.profile` and `drive.file`.
4. Choose how people sign in:
   - **Testing:** add your account under **Audience › Test users**. Sign-ins then last 7 days.
   - **Production:** publish the app. Google requires a homepage, a privacy policy and a verified domain for this.
5. Go to **Clients › Create client › iOS**. The bundle ID is the one xtool installs with:
   - with a free Apple ID: `XTL-<your team ID>.com.dedstudio.dedpad` (xtool prints it when it installs)
   - with a paid account: `com.dedstudio.dedpad`
6. Write the client ID into the app's config, then rebuild:
   ```bash
   ./scripts/configure-google.sh <client-id>.apps.googleusercontent.com
   ./scripts/run-on-ipad.sh
   ```
   This writes `Resources/google.json`, which git ignores. You can also paste the client ID on the
   iPad under Settings › Google Drive backup.

The backup in Drive looks like this:
- `dedpad/library.json` holds folders and templates.
- `dedpad/<notebook title>/` holds one notebook's files.
- Only files that changed are uploaded.
- When a notebook is deleted for good, its backup goes to the Drive trash.

## Project layout

```
Package.swift            SwiftPM package (xtool app = one library product)
xtool.yml, Info.plist    app bundle settings
Resources/               app icon, fonts (OFL), google.json (generated, git-ignored)
Sources/DedpadCore/      platform-independent core (Foundation only, tested on Linux)
  Models.swift           notebooks, pages, covers, paper, elements (versioned JSON)
  LibraryStore.swift     offline-first file storage, backups, version history
  PaperTemplates.swift   the 26 paper templates
  ShapeRecognizer.swift  draw-and-hold shape snapping
  Ink.swift              open handwriting format
  Portability.swift, Zip.swift, SVG.swift, LibraryQuery.swift, PageOperations.swift, SyncMerge.swift
Sources/Dedpad/          the iPad app (SwiftUI, PencilKit, PDFKit)
  PageCanvas.swift       editor surface: one PencilKit canvas over tiled pages, palm rejection
  EditorModel.swift, EditorView.swift, Tools.swift, ...
  Backup/                Google sign-in (PKCE), Drive REST client, backup and restore
Tests/DedpadCoreTests/   unit tests for the core
scripts/                 setup, build, test and config helpers
```

### Where notebooks are stored

Everything is plain files under *On My iPad › dedpad*:

```
library.json                               folders and saved templates
Notebooks/<uuid>/notebook.json             notebook and page data (readable JSON)
Notebooks/<uuid>/drawings/<page>.drawing   PencilKit ink per page
Notebooks/<uuid>/drawings/<page>.ink.json  the same ink in an open JSON format
Notebooks/<uuid>/assets/                   imported PDFs, images, cover photo
Notebooks/<uuid>/history/                  automatic versions
```

## Design notes

- **No SwiftData:** its macros need Xcode's plugins, which don't run on Linux. Storage is
  versioned JSON plus separate drawing and asset files.
- **Google over REST, not the SDK:** Google's iOS SDKs ship as prebuilt binary frameworks. REST
  keeps the xtool build simple. The refresh token is stored in the Keychain.

## Contributing

Contributions are welcome. You may also fork dedpad and improve it for noncommercial use (see License).

1. Fork the repository and create a branch.
2. Keep platform-independent logic in `DedpadCore` and add tests there.
3. Run `./scripts/test-core.sh` and try the change on a real iPad.
4. Open a pull request.

## License

dedpad is **free for noncommercial use**. It's licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Anyone may read, use, change and share the code
for any noncommercial purpose, including personal use, study, research, and use by schools,
charities and public bodies. **Commercial use needs written permission from the author.**
Contact Dedstudio for that.

This makes dedpad *source-available* rather than "open source" in the OSI sense, because
open-source licenses can't restrict commercial use.

The bundled fonts (DM Sans and Manrope, renamed DedSans and DedDisplay) are under the
[SIL Open Font License 1.1](Resources/Fonts/OFL.txt) and are not covered by the PolyForm license.
