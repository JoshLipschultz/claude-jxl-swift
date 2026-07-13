// ICCCodec.swift
//
// Embedded ICC profile decode (ISO/IEC 18181-1 §A; libjxl v0.11.2
// icc_codec.cc + icc_codec_common.cc). A compressed profile is a U64 encoded
// size followed by that many entropy-coded bytes (41 contexts keyed on the two
// previous bytes), which decode to a *prediction residual* stream:
// `UnpredictICC` reconstructs the actual profile from a predicted 128-byte
// header, a tag-list command stream, and main-content commands
// (insert/shuffle/linear-predict/common-tag shorthands).
//
// All arithmetic mirrors libjxl exactly, including wrapping byte/word math and
// the bounded `decodeUint32` reads in the width-4 predictor.

import Foundation

private let kICCHeaderSize = 128
private let kNumICCContexts = 41
/// libjxl caps the encoded stream at 2^28; we cap the output the same way.
private let kMaxEncodedICCSize = 1 << 28
private let kMaxDecodedICCSize = 1 << 28

// MARK: - Byte-kind contexts (icc_codec_common.cc)

@inline(__always)
private func byteKind1(_ b: UInt8) -> Int {
    if b >= 97 && b <= 122 { return 0 }  // a-z
    if b >= 65 && b <= 90 { return 0 }  // A-Z
    if b >= 48 && b <= 57 { return 1 }  // 0-9
    if b == 46 || b == 44 { return 1 }  // . ,
    if b == 0 { return 2 }
    if b == 1 { return 3 }
    if b < 16 { return 4 }
    if b == 255 { return 6 }
    if b > 240 { return 5 }
    return 7
}

@inline(__always)
private func byteKind2(_ b: UInt8) -> Int {
    if b >= 97 && b <= 122 { return 0 }
    if b >= 65 && b <= 90 { return 0 }
    if b >= 48 && b <= 57 { return 1 }
    if b == 46 || b == 44 { return 1 }
    if b < 16 { return 2 }
    if b > 240 { return 3 }
    return 4
}

@inline(__always)
private func iccANSContext(_ i: Int, _ b1: UInt8, _ b2: UInt8) -> Int {
    if i <= 128 { return 0 }
    return 1 + byteKind1(b1) + byteKind2(b2) * 8
}

// MARK: - Tags as big-endian FourCCs

private func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for c in s.utf8 { v = (v << 8) | UInt32(c) }
    return v
}

private let kBkptTag = fourCC("bkpt")
private let kBtrcTag = fourCC("bTRC")
private let kBxyzTag = fourCC("bXYZ")
private let kChadTag = fourCC("chad")
private let kChrmTag = fourCC("chrm")
private let kCprtTag = fourCC("cprt")
private let kCurvTag = fourCC("curv")
private let kDescTag = fourCC("desc")
private let kDmddTag = fourCC("dmdd")
private let kDmndTag = fourCC("dmnd")
private let kGbd_Tag = fourCC("gbd ")
private let kGtrcTag = fourCC("gTRC")
private let kGxyzTag = fourCC("gXYZ")
private let kKtrcTag = fourCC("kTRC")
private let kKxyzTag = fourCC("kXYZ")
private let kLumiTag = fourCC("lumi")
private let kMlucTag = fourCC("mluc")
private let kParaTag = fourCC("para")
private let kRtrcTag = fourCC("rTRC")
private let kRxyzTag = fourCC("rXYZ")
private let kSf32Tag = fourCC("sf32")
private let kTextTag = fourCC("text")
private let kWtptTag = fourCC("wtpt")
private let kXyz_Tag = fourCC("XYZ ")

/// Tag names focused on RGB and GRAY monitor profiles (kTagStrings).
private let kTagStrings: [UInt32] = [
    kCprtTag, kWtptTag, kBkptTag, kRxyzTag, kGxyzTag, kBxyzTag,
    kKxyzTag, kRtrcTag, kGtrcTag, kBtrcTag, kKtrcTag, kChadTag,
    kDescTag, kChrmTag, kDmndTag, kDmddTag, kLumiTag,
]

/// Tag types focused on RGB and GRAY monitor profiles (kTypeStrings).
private let kTypeStrings: [UInt32] = [
    kXyz_Tag, kDescTag, kTextTag, kMlucTag, kParaTag, kCurvTag, kSf32Tag, kGbd_Tag,
]

private let kCommandTagUnknown = 1
private let kCommandTagTRC = 2
private let kCommandTagXYZ = 3
private let kCommandTagStringFirst = 4
private let kCommandInsert: UInt8 = 1
private let kCommandShuffle2: UInt8 = 2
private let kCommandShuffle4: UInt8 = 3
private let kCommandPredict: UInt8 = 4
private let kCommandXYZ: UInt8 = 10
private let kCommandTypeStartFirst = 16
private let kFlagBitOffset: UInt8 = 64
private let kFlagBitSize: UInt8 = 128

// MARK: - Helpers (icc_codec_common.cc)

/// libjxl `DecodeVarInt`, including its exact position-advance semantics: the
/// cursor moves past the terminating byte even when the loop stops at the
/// input end or the 10-byte cap (later bounds checks reject those streams).
private func decodeVarInt(_ input: [UInt8], _ inputSize: Int, _ pos: inout Int) -> UInt64 {
    var ret: UInt64 = 0
    var i = 0
    while pos + i < inputSize && i < 10 {
        ret |= UInt64(input[pos + i] & 127) << UInt64(7 * i)
        if (input[pos + i] & 128) == 0 { break }
        i += 1
    }
    pos += i + 1
    return ret
}

/// libjxl `DecodeUint32`: bounded big-endian read, 0 when out of range.
@inline(__always)
private func decodeUint32(_ data: [UInt8], size: Int, pos: Int) -> UInt32 {
    if pos + 4 > size || pos < 0 { return 0 }
    return (UInt32(data[pos]) << 24) | (UInt32(data[pos + 1]) << 16)
        | (UInt32(data[pos + 2]) << 8) | UInt32(data[pos + 3])
}

private func appendUint32(_ value: UInt32, _ data: inout [UInt8]) {
    data.append(UInt8(truncatingIfNeeded: value >> 24))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value))
}

/// `a + b > size` with overflow safety (libjxl `CheckOutOfBounds`).
private func checkOutOfBounds(_ a: UInt64, _ b: UInt64, _ size: UInt64) throws {
    let (pos, overflow) = a.addingReportingOverflow(b)
    if overflow || pos > size { throw JXLError.malformed("ICC: out of bounds") }
}

private func checkIs32Bit(_ v: UInt64) throws {
    if (v >> 32) != 0 { throw JXLError.malformed("ICC: 32-bit value expected") }
}

/// libjxl `Shuffle`: transpose of a ceil(size/width)-column, width-row matrix.
private func shuffle(_ data: inout [UInt8], size: Int, width: Int) {
    let height = (size + width - 1) / width
    var result = [UInt8](repeating: 0, count: size)
    var s = 0
    var j = 0
    for i in 0..<size {
        result[i] = data[j]
        j += height
        if j >= size {
            s += 1
            j = s
        }
    }
    for i in 0..<size { data[i] = result[i] }
}

/// Predicted first 128 header bytes, with the profile size stored big-endian
/// in the first 4 (libjxl `ICCInitialHeaderPrediction`).
private func iccInitialHeaderPrediction(_ size: UInt32) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: kICCHeaderSize)
    header[8] = 4
    let ascii: [(Int, String)] = [(12, "mntr"), (16, "RGB "), (20, "XYZ "), (36, "acsp")]
    for (pos, s) in ascii {
        for (k, c) in s.utf8.enumerated() { header[pos + k] = c }
    }
    header[70] = 246
    header[71] = 214
    header[73] = 1
    header[78] = 211
    header[79] = 45
    header[0] = UInt8(truncatingIfNeeded: size >> 24)
    header[1] = UInt8(truncatingIfNeeded: size >> 16)
    header[2] = UInt8(truncatingIfNeeded: size >> 8)
    header[3] = UInt8(truncatingIfNeeded: size)
    return header
}

/// Refines the header prediction from bytes already decoded (libjxl
/// `ICCPredictHeader`).
private func iccPredictHeader(_ icc: [UInt8], _ size: Int, _ header: inout [UInt8], _ pos: Int) {
    if pos == 8 && size >= 8 {
        header[80] = icc[4]
        header[81] = icc[5]
        header[82] = icc[6]
        header[83] = icc[7]
    }
    if pos == 41 && size >= 41 {
        if icc[40] == UInt8(ascii: "A") {
            header[41] = UInt8(ascii: "P")
            header[42] = UInt8(ascii: "P")
            header[43] = UInt8(ascii: "L")
        }
        if icc[40] == UInt8(ascii: "M") {
            header[41] = UInt8(ascii: "S")
            header[42] = UInt8(ascii: "F")
            header[43] = UInt8(ascii: "T")
        }
    }
    if pos == 42 && size >= 42 {
        if icc[40] == UInt8(ascii: "S") && icc[41] == UInt8(ascii: "G") {
            header[42] = UInt8(ascii: "I")
            header[43] = UInt8(ascii: " ")
        }
        if icc[40] == UInt8(ascii: "S") && icc[41] == UInt8(ascii: "U") {
            header[42] = UInt8(ascii: "N")
            header[43] = UInt8(ascii: "W")
        }
    }
}

/// Linear prediction of order 0-2 for width-byte integers `stride` bytes apart
/// (libjxl `LinearPredictICCValue`); all math wraps like the C original.
private func linearPredictICCValue(
    _ data: [UInt8], start: Int, i: Int, stride: Int, width: Int, order: Int
) -> UInt8 {
    @inline(__always) func predict(_ p1: Int64, _ p2: Int64, _ p3: Int64) -> Int64 {
        switch order {
        case 0: return p1
        case 1: return 2 &* p1 &- p2
        case 2: return 3 &* p1 &- 3 &* p2 &+ p3
        default: return 0
        }
    }
    let pos = start + i
    if width == 1 {
        let p1 = Int64(data[pos - stride])
        let p2 = Int64(data[pos - stride * 2])
        let p3 = Int64(data[pos - stride * 3])
        return UInt8(truncatingIfNeeded: predict(p1, p2, p3))
    } else if width == 2 {
        let p = start + (i & ~1)
        let p1 = Int64((Int(data[p - stride]) << 8) + Int(data[p - stride + 1]))
        let p2 = Int64((Int(data[p - stride * 2]) << 8) + Int(data[p - stride * 2 + 1]))
        let p3 = Int64((Int(data[p - stride * 3]) << 8) + Int(data[p - stride * 3 + 1]))
        let pred = UInt16(truncatingIfNeeded: predict(p1, p2, p3))
        return (i & 1) != 0
            ? UInt8(truncatingIfNeeded: pred)
            : UInt8(truncatingIfNeeded: pred >> 8)
    } else {
        let p = start + (i & ~3)
        // Reads are bounded by the *current* output length, matching libjxl's
        // `DecodeUint32(data, pos, p - stride)` argument order.
        let p1 = Int64(decodeUint32(data, size: pos, pos: p - stride))
        let p2 = Int64(decodeUint32(data, size: pos, pos: p - stride * 2))
        let p3 = Int64(decodeUint32(data, size: pos, pos: p - stride * 3))
        let pred = UInt32(truncatingIfNeeded: predict(p1, p2, p3))
        let shiftBytes = UInt32(3 - (i & 3))
        return UInt8(truncatingIfNeeded: pred >> (shiftBytes * 8))
    }
}

// MARK: - UnpredictICC (icc_codec.cc)

/// Decodes the prediction-residual stream back to a valid ICC profile.
private func unpredictICC(_ enc: [UInt8]) throws -> [UInt8] {
    let size = enc.count
    var pos = 0
    if pos >= size { throw JXLError.malformed("ICC: out of bounds") }
    let osize64 = decodeVarInt(enc, size, &pos)
    try checkIs32Bit(osize64)
    if osize64 > UInt64(kMaxDecodedICCSize) {
        throw JXLError.malformed("ICC: decoded profile too large")
    }
    let osize = Int(osize64)
    if pos >= size { throw JXLError.malformed("ICC: out of bounds") }
    let csize64 = decodeVarInt(enc, size, &pos)
    try checkIs32Bit(csize64)
    var cpos = pos
    try checkOutOfBounds(UInt64(pos), csize64, UInt64(size))
    let commandsEnd = cpos + Int(csize64)
    pos = commandsEnd  // data stream position

    var result = [UInt8]()
    result.reserveCapacity(osize)

    // Header.
    var header = iccInitialHeaderPrediction(UInt32(osize))
    for i in 0...kICCHeaderSize {
        if result.count == osize {
            if cpos != commandsEnd { throw JXLError.malformed("ICC: not all commands used") }
            if pos != size { throw JXLError.malformed("ICC: not all data used") }
            return result  // valid end
        }
        if i == kICCHeaderSize { break }
        iccPredictHeader(result, result.count, &header, i)
        if pos >= size { throw JXLError.malformed("ICC: out of bounds") }
        result.append(enc[pos] &+ header[i])
        pos += 1
    }
    if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }

    // Tag list.
    var numtags = decodeVarInt(enc, size, &cpos)
    if numtags != 0 {
        numtags -= 1
        try checkIs32Bit(numtags)
        appendUint32(UInt32(numtags), &result)
        var prevtagstart = UInt64(kICCHeaderSize) + numtags * 12
        var prevtagsize: UInt64 = 0
        tagLoop: while true {
            if result.count > osize { throw JXLError.malformed("ICC: invalid result size") }
            if cpos > commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
            if cpos == commandsEnd { break }  // valid end
            let command = enc[cpos]
            cpos += 1
            let tagcode = Int(command & 63)
            let tag: UInt32
            switch tagcode {
            case 0:
                break tagLoop
            case kCommandTagUnknown:
                try checkOutOfBounds(UInt64(pos), 4, UInt64(size))
                tag = decodeUint32(enc, size: size, pos: pos)
                pos += 4
            case kCommandTagTRC:
                tag = kRtrcTag
            case kCommandTagXYZ:
                tag = kRxyzTag
            default:
                guard tagcode - kCommandTagStringFirst < kTagStrings.count else {
                    throw JXLError.malformed("ICC: unknown tagcode")
                }
                tag = kTagStrings[tagcode - kCommandTagStringFirst]
            }
            appendUint32(tag, &result)

            var tagstart: UInt64
            var tagsize = prevtagsize
            if tag == kRxyzTag || tag == kGxyzTag || tag == kBxyzTag || tag == kKxyzTag
                || tag == kWtptTag || tag == kBkptTag || tag == kLumiTag {
                tagsize = 20
            }
            if (command & kFlagBitOffset) != 0 {
                if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
                tagstart = decodeVarInt(enc, size, &cpos)
            } else {
                try checkIs32Bit(prevtagstart)
                tagstart = prevtagstart + prevtagsize
            }
            try checkIs32Bit(tagstart)
            appendUint32(UInt32(tagstart), &result)
            if (command & kFlagBitSize) != 0 {
                if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
                tagsize = decodeVarInt(enc, size, &cpos)
            }
            try checkIs32Bit(tagsize)
            appendUint32(UInt32(tagsize), &result)
            prevtagstart = tagstart
            prevtagsize = tagsize

            if tagcode == kCommandTagTRC {
                appendUint32(kGtrcTag, &result)
                appendUint32(UInt32(tagstart), &result)
                appendUint32(UInt32(tagsize), &result)
                appendUint32(kBtrcTag, &result)
                appendUint32(UInt32(tagstart), &result)
                appendUint32(UInt32(tagsize), &result)
            }
            if tagcode == kCommandTagXYZ {
                try checkIs32Bit(tagstart + tagsize * 2)
                appendUint32(kGxyzTag, &result)
                appendUint32(UInt32(tagstart + tagsize), &result)
                appendUint32(UInt32(tagsize), &result)
                appendUint32(kBxyzTag, &result)
                appendUint32(UInt32(tagstart + tagsize * 2), &result)
                appendUint32(UInt32(tagsize), &result)
            }
        }
    }

    // Main content.
    while true {
        if result.count > osize { throw JXLError.malformed("ICC: invalid result size") }
        if cpos > commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
        if cpos == commandsEnd { break }  // valid end
        let command = enc[cpos]
        cpos += 1
        if command == kCommandInsert {
            if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
            let num64 = decodeVarInt(enc, size, &cpos)
            try checkOutOfBounds(UInt64(pos), num64, UInt64(size))
            let num = Int(num64)
            result.append(contentsOf: enc[pos..<(pos + num)])
            pos += num
        } else if command == kCommandShuffle2 || command == kCommandShuffle4 {
            if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
            let num64 = decodeVarInt(enc, size, &cpos)
            try checkOutOfBounds(UInt64(pos), num64, UInt64(size))
            let num = Int(num64)
            var shuffled = [UInt8](enc[pos..<(pos + num)])
            shuffle(&shuffled, size: num, width: command == kCommandShuffle2 ? 2 : 4)
            result.append(contentsOf: shuffled)
            pos += num
        } else if command == kCommandPredict {
            try checkOutOfBounds(UInt64(cpos), 2, UInt64(commandsEnd))
            let flags = enc[cpos]
            cpos += 1
            let width = Int(flags & 3) + 1
            if width == 3 { throw JXLError.malformed("ICC: invalid width") }
            let order = Int(flags & 12) >> 2
            if order == 3 { throw JXLError.malformed("ICC: invalid order") }
            var stride = width
            if (flags & 16) != 0 {
                if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
                let stride64 = decodeVarInt(enc, size, &cpos)
                if stride64 < UInt64(width) || stride64 > UInt64(Int.max) {
                    throw JXLError.malformed("ICC: invalid stride")
                }
                stride = Int(stride64)
            }
            // stride * 4 must fit inside the current output (overflow-safe form).
            if result.isEmpty || ((result.count - 1) >> 2) < stride {
                throw JXLError.malformed("ICC: invalid stride")
            }
            if cpos >= commandsEnd { throw JXLError.malformed("ICC: out of bounds") }
            let num64 = decodeVarInt(enc, size, &cpos)
            try checkOutOfBounds(UInt64(pos), num64, UInt64(size))
            let num = Int(num64)
            var shuffled = [UInt8](enc[pos..<(pos + num)])
            if width > 1 { shuffle(&shuffled, size: num, width: width) }
            let start = result.count
            for i in 0..<num {
                let predicted = linearPredictICCValue(
                    result, start: start, i: i, stride: stride, width: width, order: order)
                result.append(predicted &+ shuffled[i])
            }
            pos += num
        } else if command == kCommandXYZ {
            appendUint32(kXyz_Tag, &result)
            result.append(contentsOf: [0, 0, 0, 0])
            try checkOutOfBounds(UInt64(pos), 12, UInt64(size))
            result.append(contentsOf: enc[pos..<(pos + 12)])
            pos += 12
        } else if Int(command) >= kCommandTypeStartFirst
            && Int(command) < kCommandTypeStartFirst + kTypeStrings.count {
            appendUint32(kTypeStrings[Int(command) - kCommandTypeStartFirst], &result)
            result.append(contentsOf: [0, 0, 0, 0])
        } else {
            throw JXLError.malformed("ICC: unknown command")
        }
    }

    if pos != size { throw JXLError.malformed("ICC: not all data used") }
    if result.count != osize { throw JXLError.malformed("ICC: invalid result size") }
    return result
}

// MARK: - Entropy-coded stream (icc_codec.cc ICCReader)

/// Reads and decodes an embedded ICC profile from the codestream position
/// where `want_icc` promises one (immediately after `CustomTransformData`).
func readICCProfile(_ br: BitReader) throws -> [UInt8] {
    let encSize64 = br.readU64()
    guard encSize64 <= UInt64(kMaxEncodedICCSize) else {
        throw JXLError.malformed("ICC: encoded profile too large")
    }
    let encSize = Int(encSize64)

    guard let (code, contextMap) = decodeHistograms(
        br, numContexts: kNumICCContexts, disallowLZ77: false)
    else { throw JXLError.malformed("ICC: could not read histograms") }
    let reader = ANSSymbolReader(code: code, reader: br)

    var decompressed = [UInt8]()
    decompressed.reserveCapacity(min(encSize, 1 << 20))
    var b1: UInt8 = 0
    var b2: UInt8 = 0
    let startBits = br.bitPosition
    for i in 0..<encSize {
        // Decompression-bomb guard (libjxl "Corrupted stream" ratio check):
        // the residual stream cannot expand the consumed bits 256-fold.
        if i > 0 && (i & 0xFFFF) == 0 {
            let usedBytes = (br.bitPosition - startBits) / 8
            if i > usedBytes * 256 { throw JXLError.malformed("ICC: corrupted stream") }
        }
        let v = reader.readHybridUint(iccANSContext(i, b1, b2), br, contextMap: contextMap)
        let b = UInt8(truncatingIfNeeded: v)
        decompressed.append(b)
        b2 = b1
        b1 = b
    }
    try br.ensureInBounds("ICC profile")
    guard reader.checkANSFinalState() else {
        throw JXLError.malformed("ICC: ANS checksum failure")
    }
    return try unpredictICC(decompressed)
}
