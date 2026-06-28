// jxl — command-line front-end for JXLCore.
//
// Usage:
//   jxl info   <file.jxl>            Print dimensions and container layout.
//   jxl boxes  <file.jxl>            List ISOBMFF boxes (container files only).
//   jxl decode <file.jxl> <out.pnm>  Decode lossless image to PGM/PPM.
//   jxl vardct <file.jxl>            Preflight VarDCT global metadata.

import Foundation
import JXLCore

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
          jxl decode <file.jxl> <out.pnm>  Decode lossless image to PGM/PPM
          jxl vardct <file.jxl>            Preflight VarDCT global metadata
          jxl vardct-dc <file.jxl> [dump]  Decode VarDCT XYB DC image (lossy)

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
        let image = try JXL.decodeImage(from: bytes)
        let out = image.isFloat ? encodePFM(image) : encodePNM(image)
        do {
            try Data(out).write(to: URL(fileURLWithPath: args[3]))
            print("decoded \(image.width) x \(image.height) -> \(args[3])")
        } catch {
            fail("error: cannot write \(args[3]): \(error)")
        }

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
