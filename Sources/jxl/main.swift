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
          jxl decode <file.jxl> <out.pnm>  Decode image (lossless or lossy) to PNM
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
        if args.count >= 5 {
            switch args[4] {
            case "16": format = .uint16
            case "float": format = .float32
            default: usage()
            }
        }
        let image = try JXL.decodeImage(from: bytes, format: format)
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
        let frames = try JXL.decodeFrames(from: bytes)
        for (i, frame) in frames.enumerated() {
            let path = "\(args[3])_\(i).ppm"
            try Data(encodePNM(frame.image)).write(to: URL(fileURLWithPath: path))
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

    default:
        usage()
    }
} catch {
    fail("error: \(error)")
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
                let v = UInt32(bitPattern: image.planes[c][y * image.width + x])
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
                let v = UInt32(bitPattern: image.planes[plane][y * image.width + x])
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
