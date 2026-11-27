# MacFlow 2.0 — Test report

Run on 27 Nov 2026 · macOS 27.0.1 · Xcode 27.2 / Swift 6.4.2 · Apple silicon (arm64) ·
FFmpeg 9.0.1, cwebp 1.6 and oggenc 1.4.3 present (Homebrew).

## Summary

| Suite | Tests | Result |
|---|---|---|
| ConversionMatrixTests | 20 | ✅ all pass |
| ToolTests | 21 | ✅ all pass |
| ToolMatrixTests | 1 (244 tool runs) | ✅ all pass |
| PagerLockTests | 1 | ✅ pass |
| CoreUnitTests | 6 | ✅ all pass |
| DragAndWheelTests | 7 | ✅ all pass |
| SnapshotTests | 2 | rendered on request (`MACFLOW_SNAPSHOTS`), reviewed visually |
| **Total** | **58** | **0 failures** |

## Conversion matrix

58 generated fixtures covering every readable format family. For each fixture, **every** target
the wheel offers was executed through the same code path as the app (404 conversions, 0 failures,
full list in `conversion-matrix.txt`). For each conversion the test asserts:

* the source file's SHA-256 is unchanged,
* a new file/folder exists and is not the source,
* `IntegrityValidator` re-decoded it (frames, pages, duration, tracks, cues, archive entries, text),
* no scratch files leaked into the source folder.

Semantic checks on top: EXIF orientation 1–8 matches ImageIO's reference rendering pixel-wise;
transparency kept for HEIC and flattened to white for JPEG; GIF → APNG keeps 3 frames; 2-page TIFF
→ 2-page PDF; SVG → PDF stays vector; multi-page PDF → one PNG per page; scanned PDF → TXT via OCR
contains "4711"; DOCX text and Unicode survive PDF/Markdown; Markdown → HTML structure (headings,
lists, code, quotes, tables, links); CSV quoting, embedded newlines and leading zeros exact; XLSX
sheets, dates and cached formula values; subtitle times exact to the millisecond; 7z → ZIP keeps
paths; 24-bit FLAC → 24-bit WAV; MP4 → MOV keeps duration and tracks; repeated conversions name
results `alpha.jpg`, `alpha (2).jpg`, `alpha (3).jpg`.

## Tools

Every tool runs through `ToolRunner` with source-hash checks: compress (size reduced, target size
met or refused honestly), crop (top-left origin, pixel-exact), lossless JPEG rotation (pixels
identical, orientation tag composed correctly), PNG rotation, metadata edit/remove-all/remove-tag
(pixels identical, orientation kept, GPS removed), edit, background (square canvas), redact
(metadata stripped), annotate, resize (pixels/percent, animated GIF keeps frames), make PDF,
QR detection, PDF organize/metadata/protect/unprotect/watermark/page numbers/split/extract
text/merge, OCR → searchable PDF, video trim/rotate/mute/extract audio/snapshot/speed/compress,
audio trim (sample-exact), normalize (−1 dBFS), fade, mono, archive extract (escaping symlink
removed), archive test, path-traversal archive refused, JSON format/minify (key order and number
text preserved), subtitle shift (negative times refused), OGG Vorbis encode/decode and editing an OGG keeps OGG.

## Tool matrix

Every tool the ⌘ wheel offers was applied to every fixture it is offered for (244 runs,
`tool-matrix.txt`) with content checks: crop/rotate/resize dimensions, metadata fields stored and
pixels identical, video/audio durations, mono output, PDF page counts, watermark text, PDF metadata,
password protection, split counts, archive selection honoured, exact subtitle shifts. Four honest
refusals are expected and asserted (no subject for background removal in synthetic images; PDFs that
cannot be compressed further).

A dedicated test writes all ten metadata fields into JPEG, HEIC, PNG and TIFF files that already
carry metadata, then edits one field, clears one, removes the location and finally removes
everything — each step read back field by field.

## Bugs found and fixed during testing

* Removing a PDF password wrote a still-encrypted file → pages are now copied into a new document.
* JSON arrays → XML produced several root elements → wrapped in `<root>`.
* Scanned PDFs offered text targets that could only fail → now offered via OCR (also Extract Text).
* Metadata (2.0.1): author/title/description/copyright were written with the wrong XMP type —
  ImageIO's HEIC writer crashed on files that already had them; PNG/TIFF kept stale EXIF values;
  "remove all" left XMP fields in HEIC. Rewritten with well-formed XMP (JPEG/HEIC, no re-encoding)
  and a lossless property pass (PNG/TIFF); TIFF GPS is preserved across edits.
* MORE/BACK flipped pages back and forth while the pointer rested → pager lock.
* Missing main menu: ⌘C/⌘V/⌘A/⌘Z did not work in panel text fields → added.
* JSON/YAML containing `null` offered plist → now hidden for such files.

## Not covered automatically

* The live Finder drag gesture (needs input-synthesis rights). Covered by unit tests of its
  rules; must be checked by hand: drag a file, hold ⇧/⌘/⌃, drop on a segment.
* Liquid Glass rendering (window-server effect, not capturable offscreen). Layouts were
  reviewed via offscreen renders.
* Camera RAW, JPEG XL, EXR inputs (no samples), AirDrop and Terminal actions (system UI).
