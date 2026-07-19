// Splines.swift
//
// Spline rendering (ISO/IEC 18181-1 §C.4.4; libjxl splines.{h,cc} +
// render_pipeline/stage_splines.cc): a frame whose header sets kSplines
// (flags bit 4, value 16) carries entropy-coded quantized splines in the
// LfGlobal section between the patch dictionary and the noise parameters.
// Each spline is a sequence of control points plus 32-coefficient DCTs for
// the three color channels and the Gaussian sigma; rendering interpolates a
// centripetal Catmull-Rom curve through the control points, resamples it at
// unit arc-length intervals, and splats a Gaussian at every sample onto the
// XYB planes (before upsampling, after patches).
//
// The float math mirrors libjxl including its FastCosf/FastErff polynomial
// approximations (base/fast_math-inl.h), which feed pixel values directly.

import Foundation

// MARK: - Fast math (libjxl base/fast_math-inl.h, scalar)

let kSplinePi: Float = Float(Double.pi)

/// libjxl FastCosf: L1 error 7e-5 vs cos.
@inline(__always)
func fastCosf(_ x: Float) -> Float {
    // Step 1: range reduction to [0, 2pi)
    let pi2 = kSplinePi * 2.0
    let pi2inv = Float(0.5) / kSplinePi
    let npi2 = (x * pi2inv).rounded(.down) * pi2
    let xmodpi2 = x - npi2
    // Step 2: range reduction to [0, pi]
    let xPi = min(xmodpi2, pi2 - xmodpi2)
    // Step 3: range reduction to [0, pi/2]
    let abovePihalf = xPi >= kSplinePi / 2.0
    let xPihalf = abovePihalf ? kSplinePi - xPi : xPi
    // Step 4: Taylor-like approximation on x/4, prescaled by 2**0.75.
    let xs = xPihalf * 0.25
    let x2 = xs * xs
    let x4 = x2 * x2
    let cosPrescaling = x4 * 0.06960438 + (x2 * -0.84087373 + 1.68179268)
    // Step 5: angle duplication.
    let scale1 = cosPrescaling * cosPrescaling + -1.414213562
    let scale2 = scale1 * scale1 + -1
    // Step 6: change sign if needed.
    return abovePihalf ? -scale2 : scale2
}

/// libjxl FastErff: L1 error 7e-4 vs erf.
@inline(__always)
func fastErff(_ x: Float) -> Float {
    let xle0 = x <= 0
    let absx = abs(x)
    // 1 - 1 / ((((x * a + b) * x + c) * x + d) * x + 1)**4
    let denom1 = absx * 7.77394369e-02 + 2.05260015e-04
    let denom2 = denom1 * absx + 2.32120216e-01
    let denom3 = denom2 * absx + 2.77820801e-01
    let denom4 = denom3 * absx + 1.0
    let denom5 = denom4 * denom4
    let invDenom5 = 1.0 / denom5
    let result = 1.0 - invDenom5 * invDenom5
    return xle0 ? -result : result
}

// MARK: - Decode (libjxl Splines::Decode)

// SplineEntropyContexts (splines.h).
private let kQuantizationAdjustmentContext = 0
private let kStartingPositionContext = 1
private let kNumSplinesContext = 2
private let kNumControlPointsContext = 3
private let kControlPointsContext = 4
private let kDCTContext = 5
private let kNumSplineContexts = 6

private let kMaxNumControlPoints = 1 << 20
private let kMaxNumControlPointsPerPixelRatio = 2
/// Position sanity bound (not in spec; libjxl ValidateSplinePointPos).
private let kSplinePosLimit: Int64 = 1 << 23
/// Delta-delta sanity bound (libjxl QuantizedSpline::Decode kDeltaLimit).
private let kSplineDeltaLimit: Int64 = 1 << 30

/// One quantized spline as decoded from the bitstream.
struct QuantizedSplineData {
    /// Delta-deltas of control points after the starting point.
    var controlPoints: [(Int64, Int64)] = []
    /// 32 DCT coefficients per color channel (X, Y, B).
    var colorDCT: [[Int32]] = [[Int32]](repeating: [Int32](repeating: 0, count: 32), count: 3)
    var sigmaDCT: [Int32] = [Int32](repeating: 0, count: 32)
}

/// The frame's spline set (quantized form plus starting points).
struct SplinesData {
    var quantizationAdjustment: Int32 = 0
    var splines: [QuantizedSplineData] = []
    var startingPoints: [(x: Float, y: Float)] = []
}

@inline(__always)
private func unpackSignedSpline(_ u: UInt32) -> Int64 {
    let v = UInt64(u)
    let magnitude = Int64(v >> 1)
    return (v & 1) == 1 ? -magnitude - 1 : magnitude
}

/// Mirrors `Splines::Decode`. `numPixels` is the (pre-upsampling) frame pixel
/// count, which bounds the control point budget.
func decodeSplines(_ br: BitReader, numPixels: Int) throws -> SplinesData {
    guard
        let (code, contextMap) = decodeHistograms(
            br, numContexts: kNumSplineContexts, disallowLZ77: false)
    else { throw JXLError.malformed("could not read splines histograms") }
    let decoder = ANSSymbolReader(code: code, reader: br)

    var numSplines = Int(decoder.readHybridUint(kNumSplinesContext, br, contextMap: contextMap))
    let maxControlPoints = min(kMaxNumControlPoints, numPixels / kMaxNumControlPointsPerPixelRatio)
    guard numSplines <= maxControlPoints, numSplines + 1 <= maxControlPoints else {
        throw JXLError.malformed("too many splines: \(numSplines)")
    }
    numSplines += 1

    var result = SplinesData()

    // Starting points: first pair is absolute, the rest delta-coded.
    var lastX: Int64 = 0
    var lastY: Int64 = 0
    for i in 0..<numSplines {
        var x = Int64(decoder.readHybridUint(kStartingPositionContext, br, contextMap: contextMap))
        var y = Int64(decoder.readHybridUint(kStartingPositionContext, br, contextMap: contextMap))
        if i != 0 {
            x = unpackSignedSpline(UInt32(truncatingIfNeeded: x)) + lastX
            y = unpackSignedSpline(UInt32(truncatingIfNeeded: y)) + lastY
        }
        guard x < kSplinePosLimit, x > -kSplinePosLimit, y < kSplinePosLimit, y > -kSplinePosLimit
        else { throw JXLError.malformed("spline coordinates out of bounds") }
        result.startingPoints.append((Float(x), Float(y)))
        lastX = x
        lastY = y
    }

    result.quantizationAdjustment = Int32(
        truncatingIfNeeded: unpackSignedSpline(
            decoder.readHybridUint(kQuantizationAdjustmentContext, br, contextMap: contextMap)))

    var totalNumControlPoints = numSplines
    result.splines.reserveCapacity(numSplines)
    for _ in 0..<numSplines {
        var spline = QuantizedSplineData()
        let numControlPoints = Int(
            decoder.readHybridUint(kNumControlPointsContext, br, contextMap: contextMap))
        guard numControlPoints <= maxControlPoints else {
            throw JXLError.malformed("too many control points: \(numControlPoints)")
        }
        totalNumControlPoints += numControlPoints
        guard totalNumControlPoints <= maxControlPoints else {
            throw JXLError.malformed("too many control points: \(totalNumControlPoints)")
        }
        spline.controlPoints.reserveCapacity(numControlPoints)
        for _ in 0..<numControlPoints {
            let dx = unpackSignedSpline(
                decoder.readHybridUint(kControlPointsContext, br, contextMap: contextMap))
            let dy = unpackSignedSpline(
                decoder.readHybridUint(kControlPointsContext, br, contextMap: contextMap))
            guard dx < kSplineDeltaLimit, dx > -kSplineDeltaLimit,
                dy < kSplineDeltaLimit, dy > -kSplineDeltaLimit
            else { throw JXLError.malformed("spline delta-delta is out of bounds") }
            spline.controlPoints.append((dx, dy))
        }
        func decodeDCT(_ dct: inout [Int32]) throws {
            for i in 0..<32 {
                let v = Int32(
                    truncatingIfNeeded: unpackSignedSpline(
                        decoder.readHybridUint(kDCTContext, br, contextMap: contextMap)))
                if v == Int32.min {
                    throw JXLError.malformed("the weird number in spline DCT")
                }
                dct[i] = v
            }
        }
        for c in 0..<3 { try decodeDCT(&spline.colorDCT[c]) }
        try decodeDCT(&spline.sigmaDCT)
        result.splines.append(spline)
    }

    guard decoder.checkANSFinalState() else {
        throw JXLError.malformed("splines ANS checksum failure")
    }
    try br.ensureInBounds("splines")
    return result
}

// MARK: - Dequantization (libjxl QuantizedSpline::Dequantize)

// X, Y, B, sigma channel weights.
private let kChannelWeight: [Float] = [0.0042, 0.075, 0.07, 0.3333]
private let kSplineSqrt2: Float = 1.41421356237  // kSqrt2 as float
private let kSplineSqrt0_5: Float = 0.7071067811865476

private func adjustedQuant(_ adjustment: Int32) -> Float {
    adjustment >= 0 ? (1.0 + 0.125 * Float(adjustment)) : 1.0 / (1.0 - 0.125 * Float(adjustment))
}

private func invAdjustedQuant(_ adjustment: Int32) -> Float {
    adjustment >= 0 ? 1.0 / (1.0 + 0.125 * Float(adjustment)) : (1.0 - 0.125 * Float(adjustment))
}

/// A spline in its rendering form: control points + dequantized DCTs.
private struct DequantizedSpline {
    var controlPoints: [(x: Float, y: Float)] = []
    var colorDCT: [[Float]] = [[Float]](repeating: [Float](repeating: 0, count: 32), count: 3)
    var sigmaDCT: [Float] = [Float](repeating: 0, count: 32)
}

private func dequantizeSpline(
    _ q: QuantizedSplineData, startingPoint: (x: Float, y: Float),
    quantizationAdjustment: Int32, yToX: Float, yToB: Float, imageSize: UInt64,
    totalEstimatedAreaReached: inout UInt64
) throws -> DequantizedSpline {
    let areaLimit = min(1024 &* imageSize &+ (UInt64(1) << 32), UInt64(1) << 42)

    var result = DequantizedSpline()
    result.controlPoints.reserveCapacity(q.controlPoints.count + 1)
    let px = startingPoint.x.rounded()
    let py = startingPoint.y.rounded()
    guard px < Float(kSplinePosLimit), px > -Float(kSplinePosLimit),
        py < Float(kSplinePosLimit), py > -Float(kSplinePosLimit)
    else { throw JXLError.malformed("spline coordinates out of bounds") }
    var currentX = Int64(px)
    var currentY = Int64(py)
    result.controlPoints.append((Float(currentX), Float(currentY)))
    var currentDeltaX: Int64 = 0
    var currentDeltaY: Int64 = 0
    var manhattanDistance: UInt64 = 0
    for point in q.controlPoints {
        currentDeltaX += point.0
        currentDeltaY += point.1
        manhattanDistance &+= UInt64(abs(currentDeltaX)) &+ UInt64(abs(currentDeltaY))
        if manhattanDistance > areaLimit {
            throw JXLError.malformed("too large manhattan distance: \(manhattanDistance)")
        }
        guard currentDeltaX < kSplinePosLimit, currentDeltaX > -kSplinePosLimit,
            currentDeltaY < kSplinePosLimit, currentDeltaY > -kSplinePosLimit
        else { throw JXLError.malformed("spline coordinates out of bounds") }
        currentX += currentDeltaX
        currentY += currentDeltaY
        guard currentX < kSplinePosLimit, currentX > -kSplinePosLimit,
            currentY < kSplinePosLimit, currentY > -kSplinePosLimit
        else { throw JXLError.malformed("spline coordinates out of bounds") }
        result.controlPoints.append((Float(currentX), Float(currentY)))
    }

    let invQuant = invAdjustedQuant(quantizationAdjustment)
    for c in 0..<3 {
        for i in 0..<32 {
            let invDctFactor: Float = (i == 0) ? kSplineSqrt0_5 : 1.0
            result.colorDCT[c][i] =
                Float(q.colorDCT[c][i]) * invDctFactor * kChannelWeight[c] * invQuant
        }
    }
    for i in 0..<32 {
        result.colorDCT[0][i] += yToX * result.colorDCT[1][i]
        result.colorDCT[2][i] += yToB * result.colorDCT[1][i]
    }

    // Estimated-area accounting (hostile-input safety; libjxl formulas).
    var color = [UInt64](repeating: 0, count: 3)
    for c in 0..<3 {
        for i in 0..<32 {
            color[c] &+= UInt64((invQuant * abs(Float(q.colorDCT[c][i]))).rounded(.up))
        }
    }
    color[0] &+= UInt64(abs(yToX).rounded(.up)) &* color[1]
    color[2] &+= UInt64(abs(yToB).rounded(.up)) &* color[1]
    let maxColor = max(color[0], color[1], color[2])
    // CeilLog2Nonzero(1 + maxColor).
    let v = 1 &+ maxColor
    let ceilLog2 = UInt64(63 - v.leadingZeroBitCount) &+ ((v & (v &- 1)) != 0 ? 1 : 0)
    let logColor = max(UInt64(1), ceilLog2)
    let weightLimit =
        (Float(areaLimit) / Float(logColor) / Float(max(UInt64(1), manhattanDistance)))
        .squareRoot().rounded(.up)

    var widthEstimate: UInt64 = 0
    for i in 0..<32 {
        let invDctFactor: Float = (i == 0) ? kSplineSqrt0_5 : 1.0
        result.sigmaDCT[i] = Float(q.sigmaDCT[i]) * invDctFactor * kChannelWeight[3] * invQuant
        let weightF = (invQuant * abs(Float(q.sigmaDCT[i]))).rounded(.up)
        let weight = UInt64(min(weightLimit, max(1.0, weightF)))
        widthEstimate &+= weight &* weight &* logColor
    }
    totalEstimatedAreaReached &+= widthEstimate &* manhattanDistance
    if totalEstimatedAreaReached > areaLimit {
        throw JXLError.malformed("too large total estimated spline area")
    }
    return result
}

// MARK: - Draw cache (libjxl Splines::InitializeDrawCache)

private let kDesiredRenderingDistance: Float = 1.0

/// One Gaussian splat along a spline's arc.
struct SplineSegment {
    var centerX: Float
    var centerY: Float
    var color0: Float
    var color1: Float
    var color2: Float
    var invSigma: Float
    var sigmaOver4TimesIntensity: Float
    var maximumDistance: Float
}

/// Per-row segment lists ready for drawing.
struct SplineDrawCache {
    var segments: [SplineSegment] = []
    /// Indices into `segments`, bucketed by row via `yStart`.
    var segmentIndices: [Int] = []
    /// Size imageYsize + 1; row y's segments are `segmentIndices[yStart[y]..<yStart[y+1]]`.
    var yStart: [Int] = []
    var isEmpty: Bool { segments.isEmpty }
}

/// Cosine interpolation of 32 DCT coefficients at position `t` (libjxl
/// ContinuousIDCT; DCT-3 rescaled by sqrt(32), scalar accumulation).
private func continuousIDCT(_ dct: [Float], _ t: Float) -> Float {
    var result: Float = 0
    let tandhalf = t + 0.5
    for i in 0..<32 {
        let multiplier = Float(Double.pi / 32 * Double(i))
        let cos = fastCosf(multiplier * tandhalf)
        result = kSplineSqrt2 * (dct[i] * cos) + result
    }
    return result
}

/// Centripetal Catmull-Rom interpolation: 16 points per control-point pair
/// (libjxl DrawCentripetalCatmullRomSpline).
private func drawCentripetalCatmullRomSpline(
    _ pointsIn: [(x: Float, y: Float)]
) -> [(x: Float, y: Float)] {
    if pointsIn.isEmpty { return [] }
    if pointsIn.count == 1 { return pointsIn }
    let kNumPoints = 16
    var points = pointsIn
    var result: [(x: Float, y: Float)] = []
    result.reserveCapacity((points.count - 1) * kNumPoints + 1)
    // Extend with mirrored endpoints.
    points.insert(
        (points[0].x + (points[0].x - points[1].x), points[0].y + (points[0].y - points[1].y)),
        at: 0)
    let n = points.count
    points.append(
        (points[n - 1].x + (points[n - 1].x - points[n - 2].x),
         points[n - 1].y + (points[n - 1].y - points[n - 2].y)))
    for start in 0..<(points.count - 3) {
        let p0 = points[start]
        let p1 = points[start + 1]
        let p2 = points[start + 2]
        let p3 = points[start + 3]
        result.append(p1)
        var d = [Float](repeating: 0, count: 3)
        var t = [Float](repeating: 0, count: 4)
        t[0] = 0
        let p = [p0, p1, p2, p3]
        for k in 0..<3 {
            d[k] = hypotf(p[k + 1].x - p[k].x, p[k + 1].y - p[k].y).squareRoot()
            t[k + 1] = t[k] + d[k]
        }
        for i in 1..<kNumPoints {
            let tt = d[0] + (Float(i) / Float(kNumPoints)) * d[1]
            var a = [(x: Float, y: Float)](repeating: (0, 0), count: 3)
            for k in 0..<3 {
                let f = (tt - t[k]) / d[k]
                a[k] = (p[k].x + f * (p[k + 1].x - p[k].x), p[k].y + f * (p[k + 1].y - p[k].y))
            }
            var b = [(x: Float, y: Float)](repeating: (0, 0), count: 2)
            for k in 0..<2 {
                let f = (tt - t[k]) / (d[k] + d[k + 1])
                b[k] = (a[k].x + f * (a[k + 1].x - a[k].x), a[k].y + f * (a[k + 1].y - a[k].y))
            }
            let f = (tt - t[1]) / d[1]
            result.append((b[0].x + f * (b[1].x - b[0].x), b[0].y + f * (b[1].y - b[0].y)))
        }
    }
    result.append(points[points.count - 2])
    return result
}

/// Walks `points` at kDesiredRenderingDistance intervals, yielding each sample
/// and its distance from the previous one (libjxl ForEachEquallySpacedPoint).
private func forEachEquallySpacedPoint(
    _ points: [(x: Float, y: Float)], _ functor: ((x: Float, y: Float), Float) -> Void
) {
    guard !points.isEmpty else { return }
    var current = points[0]
    functor(current, kDesiredRenderingDistance)
    var next = 0
    while next < points.count {
        var previous = current
        var arclengthFromPrevious: Float = 0
        while true {
            if next >= points.count {
                functor(previous, arclengthFromPrevious)
                return
            }
            let dx = points[next].x - previous.x
            let dy = points[next].y - previous.y
            let arclengthToNext = (dx * dx + dy * dy).squareRoot()
            if arclengthFromPrevious + arclengthToNext >= kDesiredRenderingDistance {
                let f = (kDesiredRenderingDistance - arclengthFromPrevious) / arclengthToNext
                current = (previous.x + f * dx, previous.y + f * dy)
                functor(current, kDesiredRenderingDistance)
                break
            }
            arclengthFromPrevious += arclengthToNext
            previous = points[next]
            next += 1
        }
    }
}

/// Builds one segment per sampled point (libjxl ComputeSegments), appending
/// (row, segmentIndex) pairs for every image row the segment can touch.
private func computeSegments(
    center: (x: Float, y: Float), intensity: Float, color: [Float], sigma: Float,
    imageYsize: Int, segments: inout [SplineSegment], segmentsByY: inout [(Int, Int)]
) {
    // Sanity check sigma, inverse sigma and intensity.
    guard sigma.isFinite, sigma != 0, (1.0 / sigma).isFinite, intensity.isFinite else { return }
    let kDistanceExp: Float = 5  // JXL_HIGH_PRECISION
    var maxColor: Float = 0.01
    for c in 0..<3 { maxColor = max(maxColor, abs(color[c] * intensity)) }
    // Distance beyond which the splat drops below 10^-kDistanceExp.
    let maximumDistance = Float(
        (
            -2 * Double(sigma) * Double(sigma)
                * (log(0.1) * Double(kDistanceExp) - Double(log(maxColor)))
        ).squareRoot())
    let segment = SplineSegment(
        centerX: center.x, centerY: center.y,
        color0: color[0], color1: color[1], color2: color[2],
        invSigma: 1.0 / sigma,
        sigmaOver4TimesIntensity: 0.25 * sigma * intensity,
        maximumDistance: maximumDistance)
    let y0 = Int64((Double(center.y) - Double(maximumDistance)).rounded())
    let y1 = Int64((Double(center.y) + Double(maximumDistance)).rounded()) + 1  // one-past-the-end
    var y = max(y0, 0)
    while y < y1 {
        // libjxl records every y >= 0; rows at/after imageYsize are dropped
        // when the per-row index is built, so skipping them here is
        // equivalent (and bounds the list).
        if y >= Int64(imageYsize) { break }
        segmentsByY.append((Int(y), segments.count))
        y += 1
    }
    segments.append(segment)
}

/// Dequantizes and resamples every spline into per-row Gaussian segments
/// (libjxl Splines::InitializeDrawCache). `imageXsize`/`imageYsize` are the
/// upsampled frame dimensions; `yToX`/`yToB` the cmap base correlations.
func initializeSplineDrawCache(
    _ data: SplinesData, imageXsize: Int, imageYsize: Int, yToX: Float, yToB: Float
) throws -> SplineDrawCache {
    var cache = SplineDrawCache()
    var segmentsByY: [(Int, Int)] = []
    var totalEstimatedAreaReached: UInt64 = 0
    var splines: [DequantizedSpline] = []
    for i in 0..<data.splines.count {
        let spline = try dequantizeSpline(
            data.splines[i], startingPoint: data.startingPoints[i],
            quantizationAdjustment: data.quantizationAdjustment,
            yToX: yToX, yToB: yToB,
            imageSize: UInt64(imageXsize) * UInt64(imageYsize),
            totalEstimatedAreaReached: &totalEstimatedAreaReached)
        // Identical successive control points would divide by zero.
        for j in 1..<spline.controlPoints.count {
            if spline.controlPoints[j] == spline.controlPoints[j - 1] {
                throw JXLError.malformed("identical successive control points in spline \(i)")
            }
        }
        splines.append(spline)
    }
    // libjxl warns here in release and fails under fuzzing; enforcing the
    // bound protects against decompression bombs (see docs in splines.cc).
    let areaWarnLimit = min(
        8 &* UInt64(imageXsize) &* UInt64(imageYsize) &+ (UInt64(1) << 25), UInt64(1) << 30)
    if totalEstimatedAreaReached > areaWarnLimit {
        throw JXLError.limitExceeded("total spline area is too large")
    }

    for spline in splines {
        var pointsToDraw: [((x: Float, y: Float), Float)] = []
        let intermediatePoints = drawCentripetalCatmullRomSpline(spline.controlPoints)
        forEachEquallySpacedPoint(intermediatePoints) { point, multiplier in
            pointsToDraw.append((point, multiplier))
        }
        guard let last = pointsToDraw.last else { continue }
        let arcLength = Float(pointsToDraw.count - 2) * kDesiredRenderingDistance + last.1
        if arcLength <= 0 { continue }  // this spline wouldn't have any effect
        let invArcLength = 1.0 / arcLength
        var k = 0
        var color = [Float](repeating: 0, count: 3)
        for (point, multiplier) in pointsToDraw {
            let progressAlongArc = min(1.0, Float(k) * kDesiredRenderingDistance * invArcLength)
            k += 1
            for c in 0..<3 {
                color[c] = continuousIDCT(spline.colorDCT[c], Float(32 - 1) * progressAlongArc)
            }
            let sigma = continuousIDCT(spline.sigmaDCT, Float(32 - 1) * progressAlongArc)
            computeSegments(
                center: point, intensity: multiplier, color: color, sigma: sigma,
                imageYsize: imageYsize, segments: &cache.segments, segmentsByY: &segmentsByY)
        }
    }

    segmentsByY.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    cache.segmentIndices = segmentsByY.map { $0.1 }
    cache.yStart = [Int](repeating: 0, count: imageYsize + 1)
    for (y, _) in segmentsByY where y < imageYsize {
        cache.yStart[y + 1] += 1
    }
    for y in 0..<imageYsize {
        cache.yStart[y + 1] += cache.yStart[y]
    }
    return cache
}

// MARK: - Drawing (libjxl DrawSegments / stage_splines)

/// Adds one segment's Gaussian splat to a row (libjxl DrawSegment, scalar).
@inline(__always)
private func drawSegmentRow(
    _ segment: SplineSegment, y: Int, x0: Int, x1: Int,
    rowX: UnsafeMutablePointer<Float>, rowY: UnsafeMutablePointer<Float>,
    rowB: UnsafeMutablePointer<Float>
) {
    var x = max(Int64(x0), Int64((Double(segment.centerX) - Double(segment.maximumDistance)).rounded()))
    let xEnd = min(
        Int64(x1), Int64((Double(segment.centerX) + Double(segment.maximumDistance)).rounded()) + 1)
    let invSigma = segment.invSigma
    let half: Float = 0.5
    let oneOver2s2: Float = 0.353553391
    let sigmaOver4TimesIntensity = segment.sigmaOver4TimesIntensity
    while x < xEnd {
        let dx = Float(x) - segment.centerX
        let dy = Float(y) - segment.centerY
        let sqd = dx * dx + dy * dy
        let distance = sqd.squareRoot()
        let oneDimensionalFactor =
            fastErff((distance * half + oneOver2s2) * invSigma)
            - fastErff((distance * half - oneOver2s2) * invSigma)
        let localIntensity =
            sigmaOver4TimesIntensity * (oneDimensionalFactor * oneDimensionalFactor)
        let i = Int(x)
        rowX[i] += segment.color0 * localIntensity
        rowY[i] += segment.color1 * localIntensity
        rowB[i] += segment.color2 * localIntensity
        x += 1
    }
}

/// Adds every cached spline segment onto the XYB planes' visible region
/// (libjxl SplineStage: rows `[0, height)`, columns `[0, width)`).
func drawSplines(_ cache: SplineDrawCache, into image: inout XYBImage) {
    guard !cache.isEmpty else { return }
    let width = image.width
    let height = image.height
    let stride = image.stride
    let maxRow = min(height, cache.yStart.count - 1)
    image.x.withUnsafeMutableBufferPointer { bx in
        image.y.withUnsafeMutableBufferPointer { by in
            image.b.withUnsafeMutableBufferPointer { bb in
                let px = bx.baseAddress!
                let py = by.baseAddress!
                let pb = bb.baseAddress!
                for y in 0..<maxRow {
                    for i in cache.yStart[y]..<cache.yStart[y + 1] {
                        drawSegmentRow(
                            cache.segments[cache.segmentIndices[i]], y: y, x0: 0, x1: width,
                            rowX: px + y * stride, rowY: py + y * stride, rowB: pb + y * stride)
                    }
                }
            }
        }
    }
}
