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
final class WPState {
    private let header: WPHeader
    private(set) var prediction = [Int](repeating: 0, count: kNumWPPredictors)
    private(set) var pred: Int = 0
    private var predErrors: [[UInt32]]
    private var error: [Int32]
    private let xsize: Int

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
        self.header = header
        self.xsize = xsize
        self.predErrors = (0..<kNumWPPredictors).map { _ in [UInt32](repeating: 0, count: (xsize + 2) * 2) }
        self.error = [Int32](repeating: 0, count: (xsize + 2) * 2)
    }

    @inline(__always) private func addBits(_ x: Int) -> Int { x << kPredExtraBits }

    @inline(__always)
    private func errorWeight(_ x: UInt64, _ maxweight: UInt32) -> UInt32 {
        var shift = floorLog2(x + 1) - 5
        if shift < 0 { shift = 0 }
        let lookup = UInt64(Self.divlookup[Int(x >> UInt64(shift))])
        return UInt32(truncatingIfNeeded: 4 + ((UInt64(maxweight) * lookup) >> UInt64(shift)))
    }

    @inline(__always)
    private func weightedAverage(_ p: [Int], _ wIn: [UInt32]) -> Int {
        var w = wIn
        var weightSum: UInt32 = 0
        for i in 0..<kNumWPPredictors { weightSum += w[i] }
        let logWeight = UInt32(floorLog2(UInt64(weightSum)))
        weightSum = 0
        for i in 0..<kNumWPPredictors {
            w[i] >>= (logWeight - 4)
            weightSum += w[i]
        }
        var sum = Int(weightSum >> 1) - 1
        for i in 0..<kNumWPPredictors { sum += p[i] * Int(w[i]) }
        return (sum * Int(Self.divlookup[Int(weightSum) - 1])) >> 24
    }

    /// Computes the weighted prediction at (x, y); when `computeProperties` is
    /// set, writes the WP property into `properties[offset]`.
    func predict(
        x: Int, y: Int, xsize: Int, N nIn: Int, W wIn: Int, NE neIn: Int, NW nwIn: Int,
        NN nnIn: Int, computeProperties: Bool, properties: inout [Int32], offset: Int
    ) -> Int {
        let curRow = (y & 1) != 0 ? 0 : (xsize + 2)
        let prevRow = (y & 1) != 0 ? (xsize + 2) : 0
        let posN = prevRow + x
        let posNE = x < xsize - 1 ? posN + 1 : posN
        let posNW = x > 0 ? posN - 1 : posN

        var weights = [UInt32](repeating: 0, count: kNumWPPredictors)
        for i in 0..<kNumWPPredictors {
            let s = UInt64(predErrors[i][posN]) + UInt64(predErrors[i][posNE]) + UInt64(predErrors[i][posNW])
            weights[i] = errorWeight(s, header.w[i])
        }

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

        prediction[0] = W + NE - N
        prediction[1] = N - (((sumWN + teNE) * header.p1C) >> 5)
        prediction[2] = W - (((sumWN + teNW) * header.p2C) >> 5)
        prediction[3] =
            N - ((teNW * header.p3Ca + teN * header.p3Cb + teNE * header.p3Cc
                + (NN - N) * header.p3Cd + (NW - W) * header.p3Ce) >> 5)

        pred = weightedAverage(prediction, weights)

        if ((teN ^ teW) | (teN ^ teNW)) > 0 {
            return (pred + kPredictionRound) >> kPredExtraBits
        }
        let mx = max(W, max(NE, N))
        let mn = min(W, min(NE, N))
        pred = max(mn, min(mx, pred))
        return (pred + kPredictionRound) >> kPredExtraBits
    }

    func updateErrors(_ valIn: Int, x: Int, y: Int, xsize: Int) {
        let curRow = (y & 1) != 0 ? 0 : (xsize + 2)
        let prevRow = (y & 1) != 0 ? (xsize + 2) : 0
        let val = addBits(valIn)
        error[curRow + x] = Int32(truncatingIfNeeded: pred - val)
        for i in 0..<kNumWPPredictors {
            let err = UInt32(truncatingIfNeeded: (abs(prediction[i] - val) + kPredictionRound) >> kPredExtraBits)
            predErrors[i][curRow + x] = err
            predErrors[i][prevRow + x + 1] &+= err
        }
    }
}
