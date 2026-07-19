// JPEGRecon.swift
//
// Assembles the byte-exact original JPEG from a JPEG-transcoded file: the
// jbrd box supplies the marker structure (JPEGReconData), the codestream
// supplies dimensions, sampling, the RAW integer quant tables, and the
// quantized DCT coefficients (dec_frame.cc / dec_group.cc JPEG paths), the
// container supplies Exif/XMP payloads, and the embedded ICC profile is
// re-chunked into its APP2 markers. The result feeds JPEGWriter.

import Foundation

private let kCFLFixedPointPrecision: Int32 = 11
private let kDefaultColorFactor: Int32 = 84

extension FrameDecoder {
    /// Reconstructs the original JPEG file bytes (requires a jbrd box).
    func reconstructJPEG() throws -> [UInt8] {
        guard let jbrdPayload = try containerBoxPayload("jbrd") else {
            throw JXLError.unsupported("no jbrd box (not a JPEG transcode)")
        }
        var recon = try parseJPEGReconData(jbrdPayload)

        guard !frameHeader.isModular, frameHeader.colorTransform != .xyb else {
            throw JXLError.unsupported("JPEG reconstruction of a non-transcode frame")
        }
        guard frameHeader.numPasses == 1 else {
            throw JXLError.unsupported("progressive codestream for JPEG reconstruction")
        }
        let isGray = recon.components.count == 1
        let numComponents = recon.components.count
        guard numComponents == 1 || numComponents == 3 else {
            throw JXLError.malformed("jbrd: bad component count")
        }
        // JXL plane -> JPEG component (JpegOrder): YCbCr stores Cb,Y,Cr.
        let jpegCMap: [Int] =
            isGray ? [0, 0, 0] : (frameHeader.colorTransform == .ycbcr ? [1, 0, 2] : [0, 1, 2])

        // Geometry from the codestream (dec_frame.cc).
        let width = Int(size.width)
        let height = Int(size.height)
        guard width <= 65535, height <= 65535 else {
            throw JXLError.malformed("jbrd: dimensions exceed JPEG limits")
        }
        let kH = [0, 1, 1, 0]
        let kV = [0, 1, 0, 1]
        let shifts = frameHeader.channelShifts
        for c in 0..<numComponents {
            let mode = Int(frameHeader.chromaChannelMode[c])
            var comp = recon.components[jpegCMap[c]]
            comp.hSampFactor = frameHeader.colorTransform == .ycbcr ? 1 << kH[mode] : 1
            comp.vSampFactor = frameHeader.colorTransform == .ycbcr ? 1 << kV[mode] : 1
            comp.widthInBlocks = dim.xsizeBlocks >> shifts.h[c]
            comp.heightInBlocks = dim.ysizeBlocks >> shifts.v[c]
            comp.coeffs = [Int16](
                repeating: 0, count: comp.widthInBlocks * comp.heightInBlocks * 64)
            recon.components[jpegCMap[c]] = comp
        }

        // Quant tables from the codestream RAW tables (dec_frame.cc).
        let acGlobal = try varDCTACGlobal()
        guard let raw = acGlobal.rawQuant[0], abs(raw.den - 1.0 / (8 * 255)) <= 1e-8 else {
            throw JXLError.malformed("jbrd: quantization table is not a JPEG quant table")
        }
        let qtable = raw.qtable
        guard qtable.count == 3 * 64 else { throw JXLError.malformed("jbrd: bad RAW table") }
        var qtSet = 0
        for c in 0..<numComponents {
            let quantC = isGray ? 1 : c
            let qpos = Int(recon.components[jpegCMap[c]].quantIdx)
            qtSet |= 1 << qpos
            for x in 0..<8 {
                for y in 0..<8 {
                    recon.quant[qpos].values[x * 8 + y] = qtable[quantC * 64 + y * 8 + x]
                }
            }
        }
        for i in 0..<recon.quant.count where qtSet & (1 << i) == 0 {
            guard i > 0 else { throw JXLError.malformed("jbrd: first quant table unused") }
            recon.quant[i].values = recon.quant[i - 1].values
        }

        // Coefficients: DC from the retained quantized DC planes, AC from the
        // entropy-decoded blocks, with the JPEG CfL restoration for chroma
        // (dec_group.cc JPEG path).
        let lf = try varDCTLowFrequency()
        let coeffs = try varDCTCoefficients()
        let dcGlobalInfo = try varDCTDCGlobal().info
        guard let cc = dcGlobalInfo.colorCorrelation else {
            throw JXLError.malformed("jbrd: missing color correlation")
        }
        guard cc.colorFactor == UInt32(kDefaultColorFactor), cc.baseCorrelationX == 0,
            cc.baseCorrelationB == 0, cc.yToXDC == 0, cc.yToBDC == 0
        else { throw JXLError.malformed("jbrd: CfL map is not JPEG-compatible") }
        let meta = lf.metadata

        // dcoff: only for the identity color transform (RGB JPEGs).
        var dcoff = [Int32](repeating: 0, count: 3)
        if frameHeader.colorTransform == .none {
            for c in 0..<3 {
                guard qtable[64 * c] > 0 else { throw JXLError.malformed("jbrd: bad quant DC") }
                dcoff[c] = 1024 / qtable[64 * c]
            }
        }
        // scaled_qtable, transposed (dec_group.cc): (1 << P) * qY[i] / qC[i].
        var scaledQtable = [Int32](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for i in 0..<64 {
                let n = qtable[64 + i]
                let d = qtable[64 * c + i]
                guard n > 0, d > 0, n < 65536, d < 65536 else {
                    throw JXLError.malformed("jbrd: invalid JPEG quantization table")
                }
                scaledQtable[64 * c + (i % 8) * 8 + (i / 8)] =
                    (Int32(1) << kCFLFixedPointPrecision) * n / d
            }
        }

        let ctw = meta.colorTileWidth
        let bw = dim.xsizeBlocks
        let dcPlanes = [lf.dc.qx, lf.dc.qy, lf.dc.qb]
        var transposedY = [Int32](repeating: 0, count: 64)
        var transposed = [Int32](repeating: 0, count: 64)

        // Coefficient buffers are mutated per block; writing through the
        // component structs would copy the (potentially tens of MB) arrays on
        // every block, so they live in a local array until the loop ends.
        var compCoeffs = recon.components.map { $0.coeffs }
        let compWidthInBlocks = recon.components.map { $0.widthInBlocks }

        for block in coeffs.blocks {
            guard block.coveredX == 1, block.coveredY == 1 else {
                throw JXLError.unsupported("JPEG reconstruction requires DCT-8-only frames")
            }
            let bx = block.bx
            let by = block.by
            let tileX = bx / 8  // kColorTileDimInBlocks
            let tileY = by / 8
            let ytox = Int32(meta.ytoxMap[tileY * ctw + tileX])
            let ytob = Int32(meta.ytobMap[tileY * ctw + tileX])

            for c in [1, 0, 2] {
                if isGray && c != 1 { continue }
                let hs = shifts.h[c]
                let vs = shifts.v[c]
                let sbx = bx >> hs
                let sby = by >> vs
                if (sbx << hs) != bx || (sby << vs) != by { continue }
                guard block.coeff[c].count == 64 else {
                    throw JXLError.malformed("jbrd: missing block coefficients")
                }
                let comp = jpegCMap[c]
                let dst = (sby * compWidthInBlocks[comp] + sbx) * 64
                // JPEG XL blocks are transposed relative to JPEG.
                let src = block.coeff[c]
                for yy in 0..<8 {
                    for xx in 0..<8 {
                        transposed[yy * 8 + xx] = src[xx * 8 + yy]
                    }
                }
                let cmapV = c == 0 ? ytox : (c == 2 ? ytob : 0)
                if c == 1 {
                    transposedY = transposed
                    for i in 0..<64 {
                        compCoeffs[comp][dst + i] = Int16(clamping: transposed[i])
                    }
                } else if cmapV == 0 || !frameHeader.chromaIs444 {
                    for i in 0..<64 {
                        compCoeffs[comp][dst + i] = Int16(clamping: transposed[i])
                    }
                } else {
                    // JPEG CfL: coeff += (y * ((qt*ratio + r) >> P) + r) >> P.
                    let ratio = cmapV * (Int32(1) << kCFLFixedPointPrecision) / kDefaultColorFactor
                    let round = Int32(1) << (kCFLFixedPointPrecision - 1)
                    for i in 0..<64 {
                        let qt = scaledQtable[c * 64 + i]
                        let coeffScale = (qt * ratio + round) >> kCFLFixedPointPrecision
                        let cflFactor = (transposedY[i] * coeffScale + round)
                            >> kCFLFixedPointPrecision
                        compCoeffs[comp][dst + i] = Int16(clamping: transposed[i] + cflFactor)
                    }
                }
                // DC comes from the quantized DC plane.
                let dcVal = dcPlanes[c][sby * bw + sbx] - dcoff[c]
                compCoeffs[comp][dst] = Int16(clamping: min(max(dcVal, -2047), 2047))
                for i in 0..<64 {
                    let v = compCoeffs[comp][dst + i]
                    guard v >= -4095, v <= 4095 else {
                        throw JXLError.malformed("jbrd: JPEG DCT coefficient out of range")
                    }
                }
            }
        }
        for i in 0..<recon.components.count {
            recon.components[i].coeffs = compCoeffs[i]
        }

        // ICC / Exif / XMP payloads.
        try fillAppMarkers(&recon)

        var assembled = JPEGReconAssembled(data: recon)
        assembled.width = width
        assembled.height = height
        return try writeJPEG(assembled)
    }

    /// Returns a top-level container box payload, transparently unwrapping
    /// Brotli-compressed `brob` boxes whose inner type matches.
    private func containerBoxPayload(_ type: String) throws -> [UInt8]? {
        for box in parsed.boxes {
            if box.type == type {
                return Array(fileData[box.payload])
            }
            if box.type == "brob", box.payload.count > 4 {
                let inner = String(
                    decoding: fileData[box.payload.lowerBound..<(box.payload.lowerBound + 4)],
                    as: UTF8.self)
                if inner == type {
                    let compressed = Array(
                        fileData[(box.payload.lowerBound + 4)..<box.payload.upperBound])
                    return try Brotli.decompress(compressed, maxOutputSize: 64 << 20)
                }
            }
        }
        return nil
    }

    /// dec_jpeg_data.cc marker patch-up + decode_to_jpeg.cc SetExif/SetXmp +
    /// jpeg_data.cc SetJPEGDataFromICC.
    private func fillAppMarkers(_ recon: inout JPEGReconData) throws {
        let kIccTag = [UInt8]("ICC_PROFILE".utf8) + [0]  // 12 bytes
        let kExifTag = [UInt8]("Exif".utf8) + [0, 0]  // 6 bytes
        let kXMPTag = [UInt8]("http://ns.adobe.com/xap/1.0/".utf8) + [0]  // 29 bytes

        var numICC = 0
        for i in 0..<recon.appData.count where recon.appMarkerType[i] == .icc {
            guard recon.appData[i].count >= 17 else {
                throw JXLError.malformed("jbrd: ICC marker too small")
            }
            numICC += 1
        }
        var iccIndex = 0
        var iccPos = 0
        let icc = iccProfile ?? []
        for i in 0..<recon.appData.count {
            let sizeMinus1 = recon.appData[i].count - 1
            switch recon.appMarkerType[i] {
            case .unknown:
                continue  // full payload came from the Brotli stream
            case .icc:
                iccIndex += 1
                recon.appData[i][0] = 0xE2
                recon.appData[i][1] = UInt8(sizeMinus1 >> 8)
                recon.appData[i][2] = UInt8(sizeMinus1 & 0xFF)
                recon.appData[i].replaceSubrange(3..<15, with: kIccTag)
                recon.appData[i][15] = UInt8(iccIndex)
                recon.appData[i][16] = UInt8(numICC)
                let len = recon.appData[i].count - 17
                guard iccPos + len <= icc.count else {
                    throw JXLError.malformed("jbrd: ICC shorter than APP markers")
                }
                recon.appData[i].replaceSubrange(
                    17..<recon.appData[i].count, with: icc[iccPos..<(iccPos + len)])
                iccPos += len
            case .exif:
                guard let exif = try containerBoxPayload("Exif"), exif.count >= 4 else {
                    throw JXLError.malformed("jbrd: Exif marker without Exif box")
                }
                guard recon.appData[i].count == exif.count - 4 + 3 + kExifTag.count else {
                    throw JXLError.malformed("jbrd: Exif size mismatch")
                }
                recon.appData[i][0] = 0xE1
                recon.appData[i][1] = UInt8(sizeMinus1 >> 8)
                recon.appData[i][2] = UInt8(sizeMinus1 & 0xFF)
                recon.appData[i].replaceSubrange(3..<(3 + kExifTag.count), with: kExifTag)
                // The box's first 4 bytes are the TIFF header offset, not
                // part of the JPEG payload.
                recon.appData[i].replaceSubrange(
                    (3 + kExifTag.count)..<recon.appData[i].count, with: exif[4...])
            case .xmp:
                guard let xmp = try containerBoxPayload("xml ") else {
                    throw JXLError.malformed("jbrd: XMP marker without xml box")
                }
                guard recon.appData[i].count == xmp.count + 3 + kXMPTag.count else {
                    throw JXLError.malformed("jbrd: XMP size mismatch")
                }
                recon.appData[i][0] = 0xE1
                recon.appData[i][1] = UInt8(sizeMinus1 >> 8)
                recon.appData[i][2] = UInt8(sizeMinus1 & 0xFF)
                recon.appData[i].replaceSubrange(3..<(3 + kXMPTag.count), with: kXMPTag)
                recon.appData[i].replaceSubrange(
                    (3 + kXMPTag.count)..<recon.appData[i].count, with: xmp)
            }
        }
        if iccPos != icc.count && iccPos != 0 {
            throw JXLError.malformed("jbrd: ICC longer than APP markers")
        }
    }
}
