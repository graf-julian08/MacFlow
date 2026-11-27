# MacFlow 2.0

Native macOS menu-bar app: start dragging any file, hold a key, drop it on a
wheel segment.

| Key (default) | Wheel | What it does |
|---|---|---|
| ⇧ Shift | **Convert** | Writes the file in another format |
| ⌘ Command | **File Tools** | Opens a tool panel (compress, metadata, edit, crop, rotate, redact, add background, …) |
| ⌃ Control | **File Actions** | AirDrop, Float shelf, Copy, Move, Copy Path, Terminal |

* The wheel stays open once it appears — you can let go of the key and press another mode's key to switch.
* Dropping in the centre, in a gap or outside the wheel does nothing; the file returns where it was.
* Results are **new files** next to the original (`photo.png`, `photo-cropped.jpg`, `photo (2).png` …).
  Originals are only read. Existing files are never overwritten.
* Every result is decoded again and checked before it is published; a failed check deletes it and shows the reason.
* Progress, success ("Show" in Finder) and errors appear in a glass status card at the top of the screen.

## Install

```sh
./build.sh --install     # build, sign, install to /Applications and launch
./create-dmg.sh          # release/MacFlow-<version>.dmg for other Macs
```

Requirements: Apple silicon, macOS 15+ (Liquid Glass on macOS 26+), Xcode 16+ to build.
MacFlow starts at login by default (`SMAppService`; toggle in Settings → General).

**Distribution.** `build.sh` signs with a *Developer ID Application* certificate when one is in the
keychain and notarizes when `NOTARY_PROFILE` names a `notarytool` keychain profile. Without a
Developer ID (the current state on this Mac: only *Apple Development* certificates), other users
must allow the app once in System Settings → Privacy & Security → "Open Anyway". The DMG's
"Read Me" explains this. Frictionless installation for others requires an Apple Developer
Program membership.

**Permissions.** None are required — drag detection reads the drag pasteboard, mouse-button
and modifier state only. Accessibility is optional (arrow keys inside the wheel).

## How the drag integration works

`DragSessionTracker` samples, at 5 Hz while idle and 60 Hz while the mouse button is down,
the system drag pasteboard (`NSPasteboard(name: .drag)`), `NSEvent.pressedMouseButtons` and
`NSEvent.modifierFlags`. A session starts when the drag pasteboard changes during a press and
contains existing file URLs — from Finder, the Desktop or any app providing real files.

The wheel is a non-activating `NSPanel` (it can never become key, Finder keeps focus) with
`DragDestinationView` covering it. Two details fix the old "the file just moves in Finder" bug:

1. **Allowed drag operation.** Holding ⌘ restricts the source mask to `.generic`, ⌃ to `.link`.
   The wheel now always answers with an operation inside the mask (copy → generic → link,
   never move). Previously it always answered `.copy`, so AppKit rejected the drop under ⌘/⌃
   and Finder received it.
2. **Sticky wheel.** Releasing the modifier no longer closes the wheel; only the end of the
   drag does. A drop is accepted only over a segment.

Files are always taken from the *drop's own* pasteboard; nothing is cached between drags.

## Architecture

```
MacFlow/
  App/            main.swift, AppDelegate (status item, wiring), OperationCenter (jobs, HUD)
  Integration/    DragSessionTracker, RadialPanelController, DragDestinationView
  Core/           FormatRegistry, FileClassifier (magic bytes), EngineCapabilities (live probes),
                  ConversionCatalog (targets per file), ConversionService, IntegrityValidator,
                  OutputPublisher (work dir → atomic renamex_np(RENAME_EXCL)), ProcessRunner
  Engines/        Image (ImageIO/CoreImage, WebP via cwebp), PDF (PDFKit), Document (TextKit,
                  Markdown), Data (JSON/YAML/plist/XML/CSV/XLSX), Subtitle, Media (AVFoundation,
                  optional FFmpeg), Archive (bsdtar)
  Tools/          ToolCatalog, ToolRunner, ImageTools, VideoTools/AudioTools, PDFTools
  UI/             RadialMenu, ToolPanels (one glass panel per tool), HUD, FloatingShelf, Settings
MacFlowTests/     Fixtures (real sample files for every format), conversion matrix,
                  semantic checks, tool tests, unit tests, optional UI snapshots
```

Nothing is offered unless it works on *this* Mac: image formats come from ImageIO's live
reader/writer lists, FFmpeg targets from `ffmpeg -encoders` (experimental encoders excluded),
and per-file facts decide the rest (a scanned PDF offers OCR text, JSON containing `null` is not
offered as plist, the source format never appears as a target).

## Formats

The live list is in **Settings → Formats**. Verified by the test suite (`docs/conversion-matrix.txt`,
404 conversions, all passing):

* **Images** — read: JPEG, PNG/APNG, HEIC/HEIF, WebP, TIFF (multi-page), AVIF, BMP, GIF (animated),
  JPEG 2000, JPEG XL, ICO, ICNS, PSD, TGA, OpenEXR, SVG, camera RAW (as supported by macOS).
  Write: PNG, JPEG, HEIC, TIFF, AVIF, BMP, GIF, JPEG 2000, ICO, ICNS, PDF (SVG stays vector,
  JPEG embedded without recompression), WebP (needs cwebp or FFmpeg with libwebp).
* **PDF** → PNG/JPEG/HEIC (one file or a folder per page), multi-page TIFF, TXT, Markdown;
  DOCX/RTF/HTML as *best effort* (confirmation asked). Scanned PDFs → TXT/DOCX via OCR.
* **Documents** — TXT, Markdown, HTML, RTF, RTFD, DOCX, DOC, ODT, WebArchive → PDF, DOCX, RTF,
  HTML, Markdown, TXT, ODT, DOC.
* **Spreadsheets** — CSV ↔ TSV, → JSON, HTML; XLSX → CSV/TSV (one file per sheet), JSON, HTML.
* **Data** — JSON ↔ YAML, JSON → plist/XML/CSV, plist → JSON/YAML/XML, XML → JSON.
* **Subtitles** — SRT, VTT, SBV, ASS/SSA, LRC → SRT, VTT, SBV, TXT (millisecond-exact).
* **Audio** — MP3, M4A, AAC, WAV, FLAC, AIFF, CAF, OGG Vorbis, Opus, AMR, AC3 (+ WMA, APE, MKA with
  FFmpeg) → M4A, WAV, FLAC, AIFF, CAF (keeps bit depth); MP3/Opus with FFmpeg, OGG with oggenc
  (or an FFmpeg built with libvorbis).
* **Video** — MP4, MOV, M4V, 3GP (+ MKV, WebM, AVI, WMV, MPEG, TS, FLV, OGV with FFmpeg) → MP4,
  MOV, M4V (stream copy when possible), GIF, M4A; MKV/WebM/MP3 with FFmpeg.
* **Archives** — ZIP, 7z, RAR (read), TAR, TAR.GZ/BZ2/XZ, CPIO, CAB, ISO ↔ ZIP, 7z, TAR(.GZ/.BZ2/.XZ);
  folders and multi-file drops → one archive.

## Tools (⌘ wheel)

| Type | Tools |
|---|---|
| Image | Compress (format, quality, max size, target size with exact estimate), Metadata (view all tags, edit, delete single tags, remove location/all — written without recompression, pixels verified identical), Edit (exposure, contrast, saturation, vibrance, warmth, highlights, shadows, sharpness, blur, vignette, auto), Crop (handles, aspect presets), Rotate (lossless for JPEG/HEIC), Redact (Vision faces + text, manual areas, black/pixelate/blur, strips metadata), Add Background · More: Resize, Remove Background (Vision), Read QR, Annotate, Make PDF |
| Video | Compress (HEVC/H.264, quality, resolution, 30 fps), Trim and Rotate (no re-encoding), Mute, Extract Audio, Snapshot (frame-exact), Speed |
| Audio | Trim (sample-accurate, waveform), Volume/Normalize, Fade, Channels |
| PDF | Compress, Pages (reorder, rotate, delete, duplicate, keep), Metadata, Protect/Unprotect, Watermark, Page Numbers, OCR (searchable PDF or text), Split, Extract Text, Merge (several PDFs) |
| Archive | Extract (safe), Contents (choose files, password), Test |
| JSON / subtitles | Format, Minify / Shift Timing |

## Safety

* Work happens in a private folder on the destination volume; results are validated, then moved
  into place with `renamex_np(RENAME_EXCL)` — atomic and never overwriting.
* Archives: `..`/absolute paths refused, symlinks escaping the folder removed, zip-bomb guard
  (> 1 GB and > 100× ratio), disk-space check. Extracted files are never opened or run.
* Helpers run with an argument array (no shell), a fixed `PATH`, cancellation and a timeout.
* Password-protected PDFs/archives are only opened with a password the user enters.

## Libraries and licences

No third-party code is linked or bundled. MacFlow uses Apple frameworks (AppKit, SwiftUI,
ImageIO, Core Image, AVFoundation, PDFKit, Vision, ServiceManagement) and macOS's own
`bsdtar` (libarchive, BSD licence) and `ditto`. Optional helpers are *not* shipped; if the
user installed them, MacFlow uses them from `/opt/homebrew/bin`, `/usr/local/bin` or
`/opt/local/bin`: FFmpeg (LGPL/GPL depending on the build), cwebp (BSD-3-Clause), oggenc from
vorbis-tools (GPL-2.0, run as a separate program; libvorbis itself is BSD-3-Clause).

## Known limitations

* The real Finder → wheel → drop gesture cannot be automated without Accessibility rights for the
  test runner; its rules (drop-operation masks, hit-testing, sticky mode switching, pasteboard
  parsing) are unit-tested, the gesture itself must be tried by hand.
* Not notarized (no Developer ID on this Mac) — see *Distribution*.
* CJK text in PDFs generated from documents displays correctly, but some characters are extracted
  as Unicode compatibility radicals by the macOS PDF text layer.
* Camera RAW support follows macOS; no RAW sample was available for testing.
* JPEG XL, PSD, TGA, EXR: read only. WebP output, MKV/WebM/AVI/… input and MP3/Opus/OGG output need
  the optional helpers (on this Mac all are installed: FFmpeg, cwebp, oggenc).
* Pages, Numbers, Keynote, PPTX/PPT, XLS, ODS, EPUB are recognised but not converted (no local
  engine); the wheel says so.
* XLSX export contains values only (cached formula results; no formatting or charts).
* Video Compress/Trim/Rotate/Mute keep video and audio tracks; subtitle and chapter tracks are not
  carried over. HDR sources are compressed to 8-bit SDR.
* Native audio conversions (WAV/FLAC/AIFF/CAF) do not copy tags; M4A export and FFmpeg paths do.
* The optional Finder "Enter mode" from the original specification is not implemented.

## Tests

```sh
swift test                                   # 55 tests (2 snapshot tests skipped)
MACFLOW_REPORT=/tmp/matrix.txt swift test    # also writes the conversion report
MACFLOW_SNAPSHOTS=/tmp/snaps swift test --filter SnapshotTests   # renders wheels and panels
```

See `docs/TEST_REPORT.md`.
