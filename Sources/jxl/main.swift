// jxl — command-line front-end for JXLCore.
//
// Usage:
//   jxl info   <file.jxl>            Print dimensions and container layout.
//   jxl boxes  <file.jxl>            List ISOBMFF boxes (container files only).
//   jxl decode <file.jxl> <out.pnm>  Decode lossless image to PGM/PPM.
//   jxl vardct <file.jxl>            Preflight VarDCT global metadata.

import Foundation
@_spi(Stages) import JXLCore

func colorSpaceName(_ colorSpace: JXLColorSpace) -> String {
    switch colorSpace {
    case .rgb: return "RGB"
    case .grayscale: return "Grayscale"
    case .xyb: return "XYB"
    case .unknown: return "Unknown"
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    let text = """
        jxl — pure-Swift JPEG XL tools

        USAGE:
          jxl info   <file.jxl>            Print dimensions and container layout
          jxl boxes  <file.jxl>            List ISOBMFF container boxes
          jxl decode <file.jxl> <out.pnm> [16|float|nospot|dither]
                                           Decode image (lossless or lossy) to PNM;
                                           "dither" = blue-noise dither 8-bit output
                                           (djxl 0.12 default)
          jxl encode <in> <out.jxl>        Encode losslessly: PGM/PPM (int),
                                           PAM P7 (gray/RGB + alpha), PFM (float32)
          jxl icc    <file.jxl> [out.icc]  Extract the embedded ICC profile
          jxl vardct <file.jxl>            Preflight VarDCT global metadata
          jxl vardct-dc <file.jxl> [dump]  Decode VarDCT XYB DC image (lossy)
          jxl vardct-acmeta <file.jxl>     Decode VarDCT AC metadata (strategy/quant)
          jxl vardct-acglobal <file.jxl>   Decode VarDCT AC global (coeff orders)
          jxl vardct-ac <file.jxl>         Decode VarDCT AC coefficients (entropy)
          jxl vardct-decode <f.jxl> <ppm>  Reconstruct lossy VarDCT image to sRGB PPM

        """
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

let command = args[1]
let path = args[2]
let url = URL(fileURLWithPath: path)

guard let data = try? Data(contentsOf: url) else {
    fail("error: cannot read \(path)")
}
let bytes = [UInt8](data)

do {
    switch command {
    case "info":
        let info = try JXL.readInfo(from: bytes)
        let kind = info.isContainer ? "container" : "bare codestream"
        let sampleKind =
            info.bitDepth.isFloatingPoint
            ? "\(info.bitDepth.bitsPerSample)-bit float (\(info.bitDepth.exponentBitsPerSample) exponent bits)"
            : "\(info.bitDepth.bitsPerSample)-bit"
        let colorSpace = colorSpaceName(info.colorSpace)
        let channels =
            info.hasAlpha
            ? "\(colorSpace)+Alpha"
            : colorSpace
        print("\(info.width) x \(info.height)  \(sampleKind) \(channels)  (\(kind))")
        let ce = info.colorEncoding
        if ce.wantICC {
            print("color: ICC profile")
        } else {
            let transfer = ce.hasGamma ? "gamma(\(ce.gamma))" : "tf=\(ce.transferFunction)"
            print(
                "color: \(colorSpace) white_point=\(ce.whitePoint) primaries=\(ce.primaries) \(transfer) intent=\(ce.renderingIntent)"
            )
        }
        if !info.boxTypes.isEmpty {
            print("boxes: \(info.boxTypes.joined(separator: ", "))")
        }
        if info.orientation != 1 || info.hasAnimation {
            print(
                "orientation: \(info.orientation), animation: \(info.hasAnimation ? "yes" : "no")")
        }

    case "boxes":
        let parsed = try JXLContainer.parse(bytes)
        if !parsed.isContainer {
            print("bare codestream (no boxes), \(bytes.count) bytes")
        } else {
            for box in parsed.boxes {
                print("'\(box.type)'  \(box.totalSize) bytes  (payload \(box.payload.count))")
            }
        }

    case "decode":
        guard args.count >= 4 else { usage() }
        var format = JXLSampleFormat.uint8
        var renderSpots = true
        var dither = false
        for arg in args.dropFirst(4) {
            switch arg {
            case "16": format = .uint16
            case "float": format = .float32
            case "nospot": renderSpots = false  // djxl --norender_spotcolors
            case "dither": dither = true  // djxl 0.12 8-bit default
            default: usage()
            }
        }
        var image = try JXL.decodeImage(
            from: bytes, format: format, renderSpotColors: renderSpots, dither: dither)
        // Match djxl: EXIF orientation is applied to the output raster.
        if let info = try? JXL.readInfo(from: bytes), info.orientation != 1 {
            image = JXL.applyOrientation(image, orientation: info.orientation)
        }
        let wantPAM = args[3].lowercased().hasSuffix(".pam")
        let out =
            image.isFloat
            ? encodePFM(image)
            : (wantPAM && image.extraChannels > 0 ? encodePAM(image) : encodePNM(image))
        do {
            try Data(out).write(to: URL(fileURLWithPath: args[3]))
            print("decoded \(image.width) x \(image.height) -> \(args[3])")
        } catch {
            fail("error: cannot write \(args[3]): \(error)")
        }

    case "frames":
        guard args.count >= 4 else { usage() }
        var frameFormat = JXLSampleFormat.uint8
        if args.count >= 5 {
            switch args[4] {
            case "16": frameFormat = .uint16
            case "float": frameFormat = .float32
            default: usage()
            }
        }
        let frames = try JXL.decodeFrames(from: bytes, format: frameFormat)
        for (i, frame) in frames.enumerated() {
            let isFloat = frame.image.isFloat
            let path = "\(args[3])_\(i).\(isFloat ? "pfm" : "ppm")"
            let out = isFloat ? encodePFM(frame.image) : encodePNM(frame.image)
            try Data(out).write(to: URL(fileURLWithPath: path))
            print("frame \(i): \(frame.image.width) x \(frame.image.height)  duration \(frame.durationTicks) ticks -> \(path)")
        }

    case "jbrd":
        print(try describeJBRD(from: bytes))

    case "tojpeg":
        guard args.count >= 4 else { usage() }
        let jpeg = try JXL.reconstructJPEG(from: bytes)
        try jpeg.write(to: URL(fileURLWithPath: args[3]))
        print("reconstructed \(jpeg.count) JPEG bytes -> \(args[3])")

    case "vardct":
        let info = try JXL.readVarDCTInfo(from: bytes)
        print(
            "VarDCT frame: groups=\(info.frame.numGroups), dcGroups=\(info.frame.numDCGroups), passes=\(info.frame.numPasses)"
        )
        print(
            "DC quantizer: globalScale=\(info.dcGlobal.quantizer.globalScale), quantDC=\(info.dcGlobal.quantizer.quantDC)"
        )
        let treeNodes = info.dcGlobal.modularGlobalTreeNodeCount.map(String.init) ?? "not parsed"
        let blockCtx = info.dcGlobal.blockContextMap
        print(
            "DC quant default: \(info.dcGlobal.dcQuantIsDefault), block ctx default: \(info.dcGlobal.blockContextMapIsDefault), block contexts=\(blockCtx.numContexts), dc contexts=\(blockCtx.numDCContexts), modular tree nodes: \(treeNodes)"
        )
        if let colorCorrelation = info.dcGlobal.colorCorrelation {
            print("color correlation default: \(colorCorrelation.allDefault)")
        } else {
            print("color correlation: not parsed")
        }
        if let ac = info.acGlobal {
            let histogramState =
                ac.histogramsParsed ? "parsed" : "not parsed (custom coefficient orders)"
            print(
                "AC dequant default: \(ac.dequantMatricesAreDefault), histograms=\(ac.numHistograms) [\(histogramState)], orders=\(ac.usedOrdersPerPass)"
            )
        } else {
            print("AC global: coalesced in single section (not preflighted yet)")
        }

    case "vardct-acmeta":
        let m = try decodeVarDCTACMetadata(from: bytes)
        var hist = [Int](repeating: 0, count: 27)
        var covered = 0
        for i in 0..<(m.widthBlocks * m.heightBlocks) {
            if m.isFirstBlock[i] { hist[Int(m.strategy[i])] += 1 }
        }
        for q in m.quantField where q > 0 { covered += 1 }
        let names = [
            "DCT8", "ID", "DCT2", "DCT4", "DCT16", "DCT32", "DCT16x8", "DCT8x16", "DCT32x8",
            "DCT8x32", "DCT32x16", "DCT16x32", "DCT4x8", "DCT8x4", "AFV0", "AFV1", "AFV2", "AFV3",
            "DCT64", "DCT64x32", "DCT32x64", "DCT128", "DCT128x64", "DCT64x128", "DCT256",
            "DCT256x128", "DCT128x256",
        ]
        print("VarDCT AC metadata: \(m.widthBlocks) x \(m.heightBlocks) blocks, \(m.varblockCount) varblocks")
        let used = hist.enumerated().filter { $0.element > 0 }
            .map { "\(names[$0.offset])=\($0.element)" }
        print("  strategies: \(used.joined(separator: " "))")
        var qlo = Int32.max, qhi = Int32.min
        for q in m.quantField { qlo = min(qlo, q); qhi = max(qhi, q) }
        print("  quant field: [\(qlo), \(qhi)] over \(covered)/\(m.widthBlocks * m.heightBlocks) blocks")
        print("  color tiles: \(m.colorTileWidth) x \(m.colorTileHeight)")
        if args.count > 3 {
            var out = ""
            for by in 0..<m.heightBlocks {
                for bx in 0..<m.widthBlocks {
                    let i = by * m.widthBlocks + bx
                    if m.isFirstBlock[i] { out += "\(bx) \(by) \(m.strategy[i])\n" }
                }
            }
            try out.write(toFile: args[3], atomically: true, encoding: .utf8)
        }

    case "vardct-acglobal":
        let (meta, acg) = try decodeVarDCTACGlobalForFrame(from: bytes)
        print("VarDCT AC global: histograms=\(acg.numHistograms), passes=\(acg.codes.count)")
        print("  used ACs mask: 0x\(String(meta.usedACs, radix: 16))")
        for (p, passOrders) in acg.orders.enumerated() {
            let usedBuckets = passOrders.enumerated().filter { !$0.element.isEmpty }
                .map { "b\($0.offset / 3)c\($0.offset % 3)(\($0.element.count))" }
            print("  pass \(p): orders \(usedBuckets.joined(separator: " "))")
        }

    case "vardct-ac":
        let coeffs = try decodeVarDCTCoefficients(from: bytes)
        var byStrategy = [Int: Int]()
        for b in coeffs.blocks { byStrategy[Int(b.strategy), default: 0] += 1 }
        print("VarDCT AC coefficients: \(coeffs.blocks.count) varblocks decoded")
        print("  total nonzeros: \(coeffs.totalNonZeros)")
        let names = [
            "DCT8", "ID", "DCT2", "DCT4", "DCT16", "DCT32", "DCT16x8", "DCT8x16", "DCT32x8",
            "DCT8x32", "DCT32x16", "DCT16x32", "DCT4x8", "DCT8x4", "AFV0", "AFV1", "AFV2", "AFV3",
            "DCT64", "DCT64x32", "DCT32x64", "DCT128", "DCT128x64", "DCT64x128", "DCT256",
            "DCT256x128", "DCT128x256",
        ]
        let bs = byStrategy.sorted { $0.key < $1.key }.map { "\(names[$0.key])=\($0.value)" }
        print("  by strategy: \(bs.joined(separator: " "))")

    case "vardct-decode":
        guard args.count >= 4 else { usage() }
        let (w, h, rgb) = try reconstructVarDCTImage(from: bytes)
        var out = [UInt8]("P6\n\(w) \(h)\n255\n".utf8)
        out.append(contentsOf: rgb)
        try Data(out).write(to: URL(fileURLWithPath: args[3]))
        print("reconstructed \(w) x \(h) -> \(args[3])")

    case "icc":
        guard let profile = try JXL.readICCProfile(from: bytes) else {
            print("no embedded ICC profile (want_icc unset)")
            break
        }
        if args.count >= 4 {
            try profile.write(to: URL(fileURLWithPath: args[3]))
            print("wrote \(profile.count)-byte ICC profile -> \(args[3])")
        } else {
            let desc = profile.count >= 132
                ? String(decoding: profile[16..<20], as: UTF8.self)
                : "?"
            print("embedded ICC profile: \(profile.count) bytes, data color space '\(desc)'")
        }

    case "bench":
        let iters = args.count >= 4 ? (Int(args[3]) ?? 5) : 5
        let warm = try JXL.decodeImage(from: bytes)  // warmup + dimensions
        let mp = Double(warm.width * warm.height) / 1e6
        var best = Double.infinity
        var total = 0.0
        for _ in 0..<iters {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try JXL.decodeImage(from: bytes)
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            best = min(best, dt)
            total += dt
        }
        print(String(
            format: "%d x %d (%.2f MP)  best %6.1f ms  avg %6.1f ms  %6.2f MP/s",
            warm.width, warm.height, mp, best * 1000, total / Double(iters) * 1000, mp / best))

    case "vardct-dc":
        let dc = try decodeVarDCTDCImage(from: bytes)
        func stats(_ p: [Float]) -> String {
            var lo = Float.infinity, hi = -Float.infinity, sum: Float = 0
            var finite = true
            for v in p {
                if !v.isFinite { finite = false }
                lo = min(lo, v); hi = max(hi, v); sum += v
            }
            let mean = sum / Float(p.count)
            return String(
                format: "[%.5f, %.5f] mean=%.5f%@", lo, hi, mean, finite ? "" : " (NON-FINITE!)")
        }
        print("VarDCT DC image: \(dc.widthBlocks) x \(dc.heightBlocks) blocks")
        print("  X \(stats(dc.x))")
        print("  Y \(stats(dc.y))")
        print("  B \(stats(dc.b))")
        if args.count >= 4 {
            // Raw dump: "w h\n" header then w*h*3 little-endian float32 (x,y,b).
            var out = [UInt8]("\(dc.widthBlocks) \(dc.heightBlocks)\n".utf8)
            func emit(_ f: Float) {
                let bits = f.bitPattern
                out.append(UInt8(bits & 0xFF)); out.append(UInt8((bits >> 8) & 0xFF))
                out.append(UInt8((bits >> 16) & 0xFF)); out.append(UInt8((bits >> 24) & 0xFF))
            }
            for i in 0..<(dc.widthBlocks * dc.heightBlocks) {
                emit(dc.x[i]); emit(dc.y[i]); emit(dc.b[i])
            }
            try Data(out).write(to: URL(fileURLWithPath: args[3]))
            print("  wrote DC dump -> \(args[3])")
        }

    case "encode":
        guard args.count >= 4 else { usage() }
        // Dispatch on magic bytes: P5/P6 (PNM), P7 (PAM, alpha), PF/Pf (PFM,
        // float32).
        let image: JXLDecodedImage
        if bytes.count >= 2 && bytes[0] == UInt8(ascii: "P") && bytes[1] == UInt8(ascii: "7") {
            guard let img = parsePAM(bytes) else {
                fail("error: \(path) is not a supported PAM (GRAYSCALE_ALPHA/RGB_ALPHA)")
            }
            image = img
        } else if bytes.count >= 2 && bytes[0] == UInt8(ascii: "P")
            && (bytes[1] == UInt8(ascii: "F") || bytes[1] == UInt8(ascii: "f"))
        {
            guard let img = parsePFMInput(bytes) else {
                fail("error: \(path) is not a supported PFM (little-endian float32)")
            }
            image = img
        } else if let img = parsePNM(bytes) {
            image = img
        } else {
            fail("error: \(path) is not a binary PGM/PPM/PAM/PFM file")
        }
        let jxl = try JXL.encodeLossless(image: image)
        try Data(jxl).write(to: URL(fileURLWithPath: args[3]))
        let raw = image.width * image.height * (image.colorChannels + image.extraChannels)
            * (image.isFloat ? 4 : (image.bitsPerSample > 8 ? 2 : 1))
        let kind = image.isFloat ? "float32" : "\(image.bitsPerSample)-bit"
        let space = image.colorChannels == 1 ? "gray" : "RGB"
        let alpha = image.extraChannels > 0 ? "+alpha" : ""
        print(
            "encoded \(image.width) x \(image.height) \(kind) \(space)\(alpha) -> \(args[3]) "
                + "(\(jxl.count) bytes, raw \(raw))")

    default:
        usage()
    }
} catch {
    fail("error: \(error)")
}

/// Parses a binary PGM (P5) or PPM (P6) into encoder input planes. Maxval up
/// to 65535 (values > 255 are big-endian 16-bit per PNM); bit depth is the
/// smallest that covers maxval.
func parsePNM(_ bytes: [UInt8]) -> JXLDecodedImage? {
    var pos = 0
    func skipSpaceAndComments() {
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: "#") {
                while pos < bytes.count && bytes[pos] != UInt8(ascii: "\n") { pos += 1 }
            } else if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                pos += 1
            } else {
                break
            }
        }
    }
    func readInt() -> Int? {
        skipSpaceAndComments()
        var v = 0
        var any = false
        while pos < bytes.count, bytes[pos] >= UInt8(ascii: "0"), bytes[pos] <= UInt8(ascii: "9") {
            v = v * 10 + Int(bytes[pos] - UInt8(ascii: "0"))
            if v > 1 << 30 { return nil }
            pos += 1
            any = true
        }
        return any ? v : nil
    }
    guard bytes.count > 2, bytes[0] == UInt8(ascii: "P"),
        bytes[1] == UInt8(ascii: "5") || bytes[1] == UInt8(ascii: "6")
    else { return nil }
    let channels = bytes[1] == UInt8(ascii: "5") ? 1 : 3
    pos = 2
    guard let width = readInt(), let height = readInt(), let maxval = readInt(),
        width >= 1, height >= 1, maxval >= 1, maxval <= 65535
    else { return nil }
    pos += 1  // single whitespace byte after maxval
    let twoBytes = maxval > 255
    let bytesPerSample = twoBytes ? 2 : 1
    guard bytes.count - pos >= width * height * channels * bytesPerSample else { return nil }
    var bits = 1
    while (1 << bits) - 1 < maxval { bits += 1 }
    var planes = [[Int32]](repeating: [Int32](repeating: 0, count: width * height), count: channels)
    for i in 0..<(width * height) {
        for c in 0..<channels {
            let v: Int32
            if twoBytes {
                v = Int32(bytes[pos]) << 8 | Int32(bytes[pos + 1])  // PNM is big-endian
                pos += 2
            } else {
                v = Int32(bytes[pos])
                pos += 1
            }
            planes[c][i] = v
        }
    }
    return JXLDecodedImage(
        width: width, height: height, colorChannels: channels, extraChannels: 0,
        bitsPerSample: bits, isFloat: false, planes: planes)
}

/// Parses a binary PAM (P7) with TUPLTYPE GRAYSCALE_ALPHA or RGB_ALPHA into
/// encoder input planes (color channels + one alpha extra channel) — the dual
/// of `encodePAM`. Maxval up to 65535 (big-endian 16-bit above 255).
func parsePAM(_ bytes: [UInt8]) -> JXLDecodedImage? {
    guard bytes.count > 3, bytes[0] == UInt8(ascii: "P"), bytes[1] == UInt8(ascii: "7")
    else { return nil }
    var pos = 2
    var width = 0, height = 0, depth = 0, maxval = 0
    var tuple = ""
    // Header: newline-separated "TOKEN value" lines (# comments allowed)
    // until ENDHDR.
    while pos < bytes.count {
        var end = pos
        while end < bytes.count && bytes[end] != UInt8(ascii: "\n") { end += 1 }
        guard end < bytes.count else { return nil }
        let line = String(decoding: bytes[pos..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        pos = end + 1
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let key = parts.first else { continue }
        switch key {
        case "ENDHDR":
            guard width >= 1, height >= 1, maxval >= 1, maxval <= 65535,
                (depth == 2 && tuple == "GRAYSCALE_ALPHA")
                    || (depth == 4 && tuple == "RGB_ALPHA")
            else { return nil }
            let colorChannels = depth - 1
            let twoBytes = maxval > 255
            let bytesPerSample = twoBytes ? 2 : 1
            guard bytes.count - pos >= width * height * depth * bytesPerSample
            else { return nil }
            var bits = 1
            while (1 << bits) - 1 < maxval { bits += 1 }
            var planes = [[Int32]](
                repeating: [Int32](repeating: 0, count: width * height), count: depth)
            for i in 0..<(width * height) {
                for c in 0..<depth {
                    if twoBytes {
                        planes[c][i] = Int32(bytes[pos]) << 8 | Int32(bytes[pos + 1])
                        pos += 2
                    } else {
                        planes[c][i] = Int32(bytes[pos])
                        pos += 1
                    }
                }
            }
            return JXLDecodedImage(
                width: width, height: height, colorChannels: colorChannels,
                extraChannels: 1, bitsPerSample: bits, isFloat: false, planes: planes)
        case "WIDTH": width = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        case "HEIGHT": height = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        case "DEPTH": depth = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        case "MAXVAL": maxval = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        case "TUPLTYPE": tuple = parts.count > 1 ? String(parts[1]) : ""
        default: return nil
        }
    }
    return nil
}

/// Parses a binary PFM (`PF` RGB / `Pf` grayscale, negative scale =
/// little-endian, rows bottom-to-top) into float32 encoder input planes
/// (IEEE-754 bit patterns as Int32) — the dual of `encodePFM`.
func parsePFMInput(_ bytes: [UInt8]) -> JXLDecodedImage? {
    guard bytes.count > 3, bytes[0] == UInt8(ascii: "P"),
        bytes[1] == UInt8(ascii: "F") || bytes[1] == UInt8(ascii: "f")
    else { return nil }
    let channels = bytes[1] == UInt8(ascii: "F") ? 3 : 1
    var pos = 2
    // Three whitespace-separated tokens: width, height, scale.
    func readToken() -> String? {
        while pos < bytes.count,
            bytes[pos] == 0x20 || bytes[pos] == 0x09 || bytes[pos] == 0x0A || bytes[pos] == 0x0D
        { pos += 1 }
        let start = pos
        while pos < bytes.count,
            !(bytes[pos] == 0x20 || bytes[pos] == 0x09 || bytes[pos] == 0x0A
                || bytes[pos] == 0x0D)
        { pos += 1 }
        return pos > start ? String(decoding: bytes[start..<pos], as: UTF8.self) : nil
    }
    guard let wTok = readToken(), let hTok = readToken(), let sTok = readToken(),
        let width = Int(wTok), let height = Int(hTok), let scale = Double(sTok),
        width >= 1, height >= 1, scale < 0  // little-endian only
    else { return nil }
    pos += 1  // single whitespace byte after the scale line
    guard bytes.count - pos >= width * height * channels * 4 else { return nil }
    var planes = [[Int32]](
        repeating: [Int32](repeating: 0, count: width * height), count: channels)
    for y in stride(from: height - 1, through: 0, by: -1) {  // bottom-up
        for x in 0..<width {
            for c in 0..<channels {
                let v =
                    UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8
                    | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
                planes[c][y * width + x] = Int32(bitPattern: v)
                pos += 4
            }
        }
    }
    return JXLDecodedImage(
        width: width, height: height, colorChannels: channels, extraChannels: 0,
        bitsPerSample: 32, isFloat: true, planes: planes)
}

/// Encodes a decoded image as a binary PNM: P5 (grayscale) or P6 (RGB), 8- or
/// 16-bit. Extra channels (e.g. alpha) are not represented in PNM and dropped.
func encodePNM(_ image: JXLDecodedImage) -> [UInt8] {
    let isGray = image.colorChannels == 1
    let maxval = (1 << image.bitsPerSample) - 1
    let magic = isGray ? "P5" : "P6"
    var out = [UInt8]("\(magic)\n\(image.width) \(image.height)\n\(maxval)\n".utf8)
    let channelCount = isGray ? 1 : 3
    let twoBytes = image.bitsPerSample > 8
    for y in 0..<image.height {
        for x in 0..<image.width {
            for c in 0..<channelCount {
                // Clamp out-of-range samples (blend/palette edge cases can
                // overshoot the nominal range) rather than wrapping.
                let v = UInt32(min(max(image.planes[c][y * image.width + x], 0), Int32(maxval)))
                if twoBytes {
                    out.append(UInt8((v >> 8) & 0xFF))  // PNM is big-endian
                    out.append(UInt8(v & 0xFF))
                } else {
                    out.append(UInt8(v & 0xFF))
                }
            }
        }
    }
    return out
}

/// Encodes a decoded image with alpha as a binary PAM (P7, RGB_ALPHA or
/// GRAYSCALE_ALPHA): color channels then the first extra channel per pixel.
func encodePAM(_ image: JXLDecodedImage) -> [UInt8] {
    let isGray = image.colorChannels == 1
    let maxval = (1 << image.bitsPerSample) - 1
    let depth = image.colorChannels + 1
    let tuple = isGray ? "GRAYSCALE_ALPHA" : "RGB_ALPHA"
    var out = [UInt8](
        """
        P7
        WIDTH \(image.width)
        HEIGHT \(image.height)
        DEPTH \(depth)
        MAXVAL \(maxval)
        TUPLTYPE \(tuple)
        ENDHDR

        """.utf8)
    let twoBytes = image.bitsPerSample > 8
    for y in 0..<image.height {
        for x in 0..<image.width {
            for c in 0..<depth {
                let plane = c < image.colorChannels ? c : image.colorChannels
                let v = UInt32(min(max(image.planes[plane][y * image.width + x], 0), Int32(maxval)))
                if twoBytes {
                    out.append(UInt8((v >> 8) & 0xFF))  // PAM is big-endian
                    out.append(UInt8(v & 0xFF))
                } else {
                    out.append(UInt8(v & 0xFF))
                }
            }
        }
    }
    return out
}

/// Encodes a 32-bit-float decoded image as a binary PFM: `PF` (RGB) or `Pf`
/// (grayscale), little-endian, rows stored bottom-to-top (PFM convention).
func encodePFM(_ image: JXLDecodedImage) -> [UInt8] {
    let isGray = image.colorChannels == 1
    let channelCount = isGray ? 1 : 3
    var out = [UInt8]("\(isGray ? "Pf" : "PF")\n\(image.width) \(image.height)\n-1.0\n".utf8)
    for y in stride(from: image.height - 1, through: 0, by: -1) {
        for x in 0..<image.width {
            for c in 0..<channelCount {
                let bits = UInt32(bitPattern: image.planes[c][y * image.width + x])
                out.append(UInt8(bits & 0xFF))
                out.append(UInt8((bits >> 8) & 0xFF))
                out.append(UInt8((bits >> 16) & 0xFF))
                out.append(UInt8((bits >> 24) & 0xFF))
            }
        }
    }
    return out
}
