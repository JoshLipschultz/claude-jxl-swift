# macOS app & Quick Look extension (Milestone 10)

This directory holds the macOS-integration sources. The core decoder
(`Sources/JXLCore`) stays toolchain-light on purpose so it builds and tests
without Xcode.

## `JXLViewer` — macOS viewer app

[`JXLViewer/`](JXLViewer/) is a **document-based** AppKit application that opens
`.jxl` files and displays the decoded pixels. It's primarily a **testing
harness** for the decoder: point it at a fixture and eyeball the result. It links
`JXLCore` (as a local Swift package).

Because it's built on `NSDocument`/`NSDocumentController`, each file opens in its
**own window**, and Open Recent, drag-to-open, and window management come for
free.

**Build & run in Xcode (recommended):** the project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from
[`project.yml`](../project.yml) at the repo root, which references the existing
`Package.swift`, so `JXLCore` stays the single source of truth (no duplicated
file lists).

```
brew install xcodegen        # once
xcodegen generate            # writes JXLViewer.xcodeproj (git-ignored, disposable)
open JXLViewer.xcodeproj     # ⌘R to build & run the JXLViewer scheme
```

Edit `project.yml`, not the generated `.xcodeproj`. Full Xcode is required to
build the project (the Command Line Tools' SwiftPM build service is broken — see
the top-level README); the app itself targets macOS 13+.

**Build without Xcode (CLI-only):** `swiftc` packages a `.app` bundle directly,
matching `Scripts/build.sh`:

```
sh Scripts/build-viewer.sh              # -> .build/viewer/JXLViewer.app
sh Scripts/build-viewer.sh --run FILE   # build and launch, opening FILE
```

Any file paths passed on the command line each open in their own window
(`build-viewer.sh --run a.jxl b.jxl`), which is handy for exercising the
multi-window behaviour from the terminal.

**Features**

- **Multi-window**, one document per file (`NSDocument`); Open (⌘O), Open Recent,
  Close (⌘W), and drag-and-drop.
- **Zoom & pan** via a scroll view: Actual Size (⌘0), Zoom In/Out (⌘+/⌘−), Zoom
  to Fit (⌘9), plus trackpad pinch. Pixels stay crisp (nearest-neighbour) when
  magnified.
- **Pixel inspector**: the status bar shows the native sample values (R/G/B/A or
  grayscale, in the file's bit depth) under the cursor.
- **Metadata inspector** (⌘I): a side panel mirroring `jxl info` / `jxl vardct`
  — image metadata, colour encoding, container boxes, frame + TOC layout, and
  VarDCT globals for lossy frames.
- **Checkerboard** behind transparent images; a background thread does the decode.

Lossless Modular images render today; lossy (VarDCT) files still show the
decoder's error in the status bar but their **metadata panel is fully populated**,
so the app is already useful for inspecting them. Decode + conversion live in
[`DecodePipeline.swift`](JXLViewer/DecodePipeline.swift) and
[`JXLImageConverter.swift`](JXLViewer/JXLImageConverter.swift) (the one spot that
knows the plane layout) — reuse them from the Quick Look provider below once you
want real thumbnails.

## Quick Look extension (needs full Xcode)

A Quick Look appex needs **full Xcode** for packaging and codesigning, so the
files below are added to an Xcode project rather than built by the scripts.

## When full Xcode is installed

1. Create an Xcode project/workspace with:
   - a host **macOS app** target (the standalone `JXLViewer` above can serve as
     this, or add a minimal host), and
   - a **Quick Look Extension** target (`JXLQuickLook`).
2. Add the local SwiftPM package (this repo) as a package dependency and link the
   `JXLCore` library product into both targets.
3. Replace the generated thumbnail provider with
   [`JXLQuickLook/ThumbnailProvider.swift`](JXLQuickLook/ThumbnailProvider.swift)
   and use [`JXLQuickLook/Info.plist`](JXLQuickLook/Info.plist) (declares the
   JPEG XL UTIs `public.jpeg-xl` / `org.jpeg.jxl`).
4. For a full preview (not just thumbnails), add a `QLPreviewProvider` /
   `QLPreviewingController` target the same way.

## Dependency on the decoder

The provider currently renders an aspect-correct **placeholder** using
`JXL.readInfo`. Once Milestone 5 (Modular mode) lands and `JXLCore` can return a
`CGImage`, swap the placeholder for the decoded image — the integration point is
marked with an `M5+` comment in `ThumbnailProvider.swift`.

## Registering the UTI

macOS needs to know the app exports/imports the JPEG XL type. Add to the host
app's Info.plist an `UTImportedTypeDeclarations` entry mapping `org.jpeg.jxl`
(conforming to `public.image`) with the `jxl` filename extension and the
`image/jxl` MIME type, so Finder routes `.jxl` files to the extension.
