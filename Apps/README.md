# macOS app & Quick Look extension (Milestone 10)

This directory holds the macOS-integration sources. They are **not** built by the
SwiftPM scripts — a Quick Look appex needs **full Xcode** for packaging and
codesigning. The core decoder (`Sources/JXLCore`) stays toolchain-light on
purpose so it builds and tests without Xcode.

## When full Xcode is installed

1. Create an Xcode project/workspace with:
   - a host **macOS app** target (`JXLViewer`), and
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
