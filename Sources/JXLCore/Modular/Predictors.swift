// Predictors.swift
//
// Modular-mode predictors (libjxl modular/encoding/context_predict.h): the 14
// simple predictors and the self-correcting "weighted" predictor with its
// error-feedback state. Each decoded pixel is `UnpackSigned(residual) *
// multiplier + offset + predicted`, where `predicted` comes from one of these.
// All integer math mirrors libjxl exactly (pixel_type = Int32, the wider
// intermediate type pixel_type_w = Int).

import Foundation

private let kPredExtraBits = 3
private let kPredictionRound = ((1 << kPredExtraBits) >> 1) - 1  // 3
private let kNumWPPredictors = 4

@inline(__always)
private func floorLog2(_ x: UInt64) -> Int { 63 - Int(x.leadingZeroBitCount) }

/// Clamps the gradient predictor to the neighbourhood (libjxl `ClampedGradient`).
@inline(__always)
func clampedGradient(_ n: Int, _ w: Int, _ l: Int) -> Int {
    let m = min(n, w)
    let M = max(n, w)
    let grad = n + w - l
    let gradClampM = l < m ? M : grad
    return l > M ? m : gradClampM
}

@inline(__always)
func predictorSelect(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let p = a + b - c
    let pa = abs(p - a)
    let pb = abs(p - b)
    return pa < pb ? a : b
}

/// Evaluates one of the 14 simple predictors (libjxl `PredictOne`).
@inline(__always)
func predictOne(
    _ predictor: Int, left: Int, top: Int, toptop: Int, topleft: Int,
    topright: Int, leftleft: Int, toprightright: Int, wpPred: Int
) -> Int {
    switch predictor {
    case 0: return 0  // Zero
    case 1: return left  // Left
    case 2: return top  // Top
    case 3: return (left + top) / 2  // Average0
    case 4: return predictorSelect(left, top, topleft)  // Select
    case 5: return clampedGradient(left, top, topleft)  // Gradient
    case 6: return wpPred  // Weighted
    case 7: return topright  // TopRight
    case 8: return topleft  // TopLeft
    case 9: return leftleft  // LeftLeft
    case 10: return (left + topleft) / 2  // Average1
    case 11: return (topleft + top) / 2  // Average2
    case 12: return (top + topright) / 2  // Average3
    case 13: return (6 * top - 2 * toptop + 7 * left + leftleft + toprightright + 3 * topright + 8) / 16  // Average4
    default: return 0
    }
}

struct WPHeader {
    var p1C = 16, p2C = 10, p3Ca = 7, p3Cb = 7, p3Cc = 7, p3Cd = 0, p3Ce = 0
    var w: [UInt32] = [0xd, 0xc, 0xc, 0xc]
}

extension BitReader {
    /// Reads a weighted-predictor header (libjxl `weighted::Header`).
    func readWPHeader() -> WPHeader {
        var h = WPHeader()
        if readBool() { return h }  // all_default
        h.p1C = Int(read(5))
        h.p2C = Int(read(5))
        h.p3Ca = Int(read(5))
        h.p3Cb = Int(read(5))
        h.p3Cc = Int(read(5))
        h.p3Cd = Int(read(5))
        h.p3Ce = Int(read(5))
        h.w = [UInt32(read(4)), UInt32(read(4)), UInt32(read(4)), UInt32(read(4))]
        return h
    }
}

/// The self-correcting weighted predictor's running state (libjxl
/// `weighted::State`). Keeps a sliding two-row window of per-predictor errors.
///
/// This runs for every pixel of WP-using channels, so the state lives in flat
/// manually-managed buffers (no per-access COW/exclusivity checks) and the
/// 4-wide predictor math is fully scalarized (no per-pixel allocations).
final class WPState {
    private let p1C, p2C, p3Ca, p3Cb, p3Cc, p3Cd, p3Ce: Int
    private let hw0, hw1, hw2, hw3: UInt32
    // Last prediction (x8 fixed point) and the four sub-predictions, consumed
    // by `updateErrors` for the same pixel.
    private var pred = 0
    private var pr0 = 0, pr1 = 0, pr2 = 0, pr3 = 0
    /// Two-row sliding window stride (xsize + 2).
    private let stride: Int
    /// 4 planes of `stride * 2` per-predictor errors, contiguous.
    private let predErrors: UnsafeMutablePointer<UInt32>
    /// Two rows of `stride` signed prediction errors.
    private let error: UnsafeMutablePointer<Int32>

    private static let divlookup: [UInt32] = [
        16_777_216, 8_388_608, 5_592_405, 4_194_304, 3_355_443, 2_796_202, 2_396_745, 2_097_152,
        1_864_135, 1_677_721, 1_525_201, 1_398_101, 1_290_555, 1_198_372, 1_118_481, 1_048_576,
        986_895, 932_067, 883_011, 838_860, 798_915, 762_600, 729_444, 699_050,
        671_088, 645_277, 621_378, 599_186, 578_524, 559_240, 541_200, 524_288,
        508_400, 493_447, 479_349, 466_033, 453_438, 441_505, 430_185, 419_430,
        409_200, 399_457, 390_167, 381_300, 372_827, 364_722, 356_962, 349_525,
        342_392, 335_544, 328_965, 322_638, 316_551, 310_689, 305_040, 299_593,
        294_337, 289_262, 284_359, 279_620, 275_036, 270_600, 266_305, 262_144,
    ]

    init(header: WPHeader, xsize: Int, ysize: Int) {
        p1C = header.p1C
        p2C = header.p2C
        p3Ca = header.p3Ca
        p3Cb = header.p3Cb
        p3Cc = header.p3Cc
        p3Cd = header.p3Cd
        p3Ce = header.p3Ce
        hw0 = header.w[0]
        hw1 = header.w[1]
        hw2 = header.w[2]
        hw3 = header.w[3]
        stride = xsize + 2
        predErrors = .allocate(capacity: kNumWPPredictors * stride * 2)
        predErrors.initialize(repeating: 0, count: kNumWPPredictors * stride * 2)
        error = .allocate(capacity: stride * 2)
        error.initialize(repeating: 0, count: stride * 2)
    }

    deinit {
        predErrors.deallocate()
        error.deallocate()
    }

    @inline(__always) private func addBits(_ x: Int) -> Int { x << kPredExtraBits }

    @inline(__always)
    private func errorWeight(_ x: UInt64, _ maxweight: UInt32) -> UInt32 {
        var shift = floorLog2(x + 1) - 5
        if shift < 0 { shift = 0 }
        let lookup = UInt64(Self.divlookup[Int(x >> UInt64(shift))])
        return UInt32(truncatingIfNeeded: 4 + ((UInt64(maxweight) * lookup) >> UInt64(shift)))
    }

    /// Computes the weighted prediction at (x, y); when `computeProperties` is
    /// set, writes the WP property into `properties[offset]`.
    func predict(
        x: Int, y: Int, xsize: Int, N nIn: Int, W wIn: Int, NE neIn: Int, NW nwIn: Int,
        NN nnIn: Int, computeProperties: Bool, properties: inout [Int32], offset: Int
    ) -> Int {
        let curRow = (y & 1) != 0 ? 0 : stride
        let prevRow = (y & 1) != 0 ? stride : 0
        let posN = prevRow + x
        let posNE = x < xsize - 1 ? posN + 1 : posN
        let posNW = x > 0 ? posN - 1 : posN
        let planeSize = stride * 2

        @inline(__always) func weight(_ plane: Int, _ maxw: UInt32) -> UInt32 {
            let base = predErrors + plane * planeSize
            // libjxl sums the three neighbour errors in uint32, wrapping mod
            // 2^32 — reachable with 32-bit (float bit-pattern) samples, where
            // per-pixel errors approach 2^32. The wrap must be reproduced.
            let s = base[posN] &+ base[posNE] &+ base[posNW]
            return errorWeight(UInt64(s), maxw)
        }
        let w0In = weight(0, hw0)
        let w1In = weight(1, hw1)
        let w2In = weight(2, hw2)
        let w3In = weight(3, hw3)

        let N = addBits(nIn)
        let W = addBits(wIn)
        let NE = addBits(neIn)
        let NW = addBits(nwIn)
        let NN = addBits(nnIn)

        let teW = x == 0 ? 0 : Int(error[curRow + x - 1])
        let teN = Int(error[posN])
        let teNW = Int(error[posNW])
        let sumWN = teN + teW
        let teNE = Int(error[posNE])

        if computeProperties {
            var p = teW
            if abs(teN) > abs(p) { p = teN }
            if abs(teNW) > abs(p) { p = teNW }
            if abs(teNE) > abs(p) { p = teNE }
            properties[offset] = Int32(truncatingIfNeeded: p)
        }

        pr0 = W + NE - N
        pr1 = N - (((sumWN + teNE) * p1C) >> 5)
        pr2 = W - (((sumWN + teNW) * p2C) >> 5)
        pr3 =
            N - ((teNW * p3Ca + teN * p3Cb + teNE * p3Cc
                + (NN - N) * p3Cd + (NW - W) * p3Ce) >> 5)

        // Weighted average (libjxl weighted::State::Predict), scalarized.
        var weightSum = w0In + w1In + w2In + w3In
        let logWeight = UInt32(floorLog2(UInt64(weightSum)))
        let downShift = logWeight - 4
        let w0 = w0In >> downShift
        let w1 = w1In >> downShift
        let w2 = w2In >> downShift
        let w3 = w3In >> downShift
        weightSum = w0 + w1 + w2 + w3
        // Wrapping ops: with 32-bit samples the products can exceed Int64
        // (C++ wraps in practice; Swift must not trap).
        var sum = Int(weightSum >> 1) - 1
        sum &+= pr0 &* Int(w0) &+ pr1 &* Int(w1) &+ pr2 &* Int(w2) &+ pr3 &* Int(w3)
        pred = (sum &* Int(Self.divlookup[Int(weightSum) - 1])) >> 24

        if ((teN ^ teW) | (teN ^ teNW)) > 0 {
            return (pred + kPredictionRound) >> kPredExtraBits
        }
        let mx = max(W, max(NE, N))
        let mn = min(W, min(NE, N))
        pred = max(mn, min(mx, pred))
        return (pred + kPredictionRound) >> kPredExtraBits
    }

    func updateErrors(_ valIn: Int, x: Int, y: Int, xsize: Int) {
        let curRow = (y & 1) != 0 ? 0 : stride
        let prevRow = (y & 1) != 0 ? stride : 0
        let val = addBits(valIn)
        error[curRow + x] = Int32(truncatingIfNeeded: pred - val)
        let planeSize = stride * 2
        @inline(__always) func update(_ plane: Int, _ prediction: Int) {
            let err = UInt32(truncatingIfNeeded: (abs(prediction - val) + kPredictionRound) >> kPredExtraBits)
            let base = predErrors + plane * planeSize
            base[curRow + x] = err
            base[prevRow + x + 1] &+= err
        }
        update(0, pr0)
        update(1, pr1)
        update(2, pr2)
        update(3, pr3)
    }
}
