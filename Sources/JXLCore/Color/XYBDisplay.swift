// XYBDisplay.swift
//
// Display-time color path: expose a lossy (XYB) frame's *pre-color-transform*
// float XYB planes plus the parameters a GPU shader needs to finish the color
// conversion (opsin inverse → target primaries → HLG OOTF → linear light) at
// draw time. Producing linear target-space RGB — rather than transfer-encoded
// samples — is exactly what an extended-linear/EDR display path wants: the
// compositor applies the display transfer and HDR headroom. The CPU reference
// (`xybToLinearFloatPlanes`) computes the same `linear()` output so the GPU
// result can be validated by readback.
//
// This covers the common lossy still: a single regular VarDCT frame in XYB.
// Layered stills, animations, YCbCr (JPEG transcode) and native-Modular frames
// return nil, and callers fall back to the CPU `decodeImage` + CGImage path.

import Foundation

/// The opsin-inverse + primaries + HLG-OOTF constants a shader needs to turn
/// XYB into linear target-space RGB, mirroring `ConvertState.linear`.
public struct JXLXYBColorParams: Sendable {
    /// Inverse-opsin 3×3 (row-major) and the positive absorbance biases and
    /// their cube roots.
    public let opsinInverse: [Float]  // 9
    public let opsinBias: [Float]  // 3
    public let opsinBiasCbrt: [Float]  // 3
    /// Intensity scale (255 / intensity_target); linear 1.0 = mastering peak.
    public let opsinScale: Float
    /// Linear-sRGB → target-primaries 3×3 (row-major); nil = identity (sRGB/D65).
    public let primariesMatrix: [Float]?
    /// HLG inverse OOTF: (exponent, lumR, lumG, lumB); nil when not applied.
    public let hlgOOTF: SIMD4<Float>?
    /// Enumerated primaries (1=sRGB, 9=Rec2020, 11=P3) and transfer function,
    /// for tagging the display color space.
    public let primaries: UInt32
    public let transferFunction: UInt32
    public let intensityTarget: Float
}

/// A lossy frame's pre-color-transform XYB planes (visible `width`×`height`,
/// row-major) plus the color parameters and normalized alpha.
public struct JXLXYBFloatImage: Sendable {
    public let width: Int
    public let height: Int
    public let x: [Float]
    public let y: [Float]
    public let b: [Float]
    /// Normalized alpha (0…1), or nil when the frame has no alpha channel.
    public let alpha: [Float]?
    public let params: JXLXYBColorParams
}

extension FrameDecoder {
    /// Runs the VarDCT XYB pipeline up to (but not including) the color
    /// transform and returns the visible-cropped XYB planes + color params, or
    /// nil for frames the GPU display path does not cover.
    func decodeXYBForDisplay() throws -> JXLXYBFloatImage? {
        // Only a single regular XYB VarDCT frame that covers the canvas without
        // blending: everything else (layered, animated, YCbCr, native Modular)
        // takes the CPU path.
        guard !frameHeader.isModular, frameHeader.colorTransform == .xyb,
            frameHeader.frameType == .regular, frameHeader.isLast,
            !frameHeader.customSizeOrOrigin, !frameHeader.needsBlending
        else { return nil }

        var xyb = try reconstructXYB()
        if let patches = patchDictionary, !patches.isEmpty {
            try renderPatches(patches, into: &xyb) { try self.referenceXYBFrame($0) }
        }
        try renderSplines(into: &xyb)
        if frameHeader.upsampling > 1 {
            xyb = try upsampleXYB(xyb)
        }
        try renderNoise(into: &xyb)

        let spec = try makeOutputColorSpec(
            metadata.colorEncoding, toneMapping: metadata.toneMapping,
            customOpsin: customOpsin, icc: iccOutput)
        // ICC / .curve output keeps its own device-space conversion on the CPU;
        // the GPU path targets enumerated primaries + transfer only.
        if case .curve = spec.transfer { return nil }

        let w = dim.xsize
        let h = dim.ysize
        var x = [Float](repeating: 0, count: w * h)
        var y = [Float](repeating: 0, count: w * h)
        var b = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = row * xyb.stride
            let dst = row * w
            for col in 0..<w {
                x[dst + col] = xyb.x[src + col]
                y[dst + col] = xyb.y[src + col]
                b[dst + col] = xyb.b[src + col]
            }
        }

        // Alpha (first alpha extra channel), normalized to 0…1.
        var alpha: [Float]? = nil
        if let ai = metadata.extraChannels.firstIndex(where: { $0.type == 0 }) {
            let ecPlanes = try finalizeExtraChannels()
            if ai < ecPlanes.count {
                let bits = Int(metadata.extraChannels[ai].bitDepth.bitsPerSample)
                let scale = 1.0 / Float((1 << bits) - 1)
                alpha = ecPlanes[ai].map { Float($0) * scale }
            }
        }

        return JXLXYBFloatImage(
            width: w, height: h, x: x, y: y, b: b, alpha: alpha,
            params: spec.displayParams(colorEncoding: metadata.colorEncoding,
                intensityTarget: metadata.toneMapping.intensityTarget))
    }
}

extension OutputColorSpec {
    /// The shader-facing scalars for this spec, read from the same
    /// `ConvertState` the CPU path uses (so defaults and file-custom opsin
    /// matrices are handled identically).
    func displayParams(colorEncoding enc: JXLColorEncoding, intensityTarget: Float)
        -> JXLXYBColorParams
    {
        let s = ConvertState(self)
        let inv: [Float] = [
            s.io00, s.io01, s.io02, s.io10, s.io11, s.io12, s.io20, s.io21, s.io22,
        ]
        let bias: [Float] = [s.biasR, s.biasG, s.biasB]
        let biasCbrt: [Float] = [s.biasCbrtR, s.biasCbrtG, s.biasCbrtB]
        let ootf: SIMD4<Float>? = hlgOOTF.map {
            SIMD4<Float>($0.exponent, $0.lumR, $0.lumG, $0.lumB)
        }
        return JXLXYBColorParams(
            opsinInverse: inv, opsinBias: bias, opsinBiasCbrt: biasCbrt,
            opsinScale: s.opsinScale, primariesMatrix: matrix, hlgOOTF: ootf,
            primaries: enc.primaries, transferFunction: enc.transferFunction,
            intensityTarget: intensityTarget)
    }
}

/// CPU reference for the GPU path: linear target-space RGB float planes
/// (`ConvertState.linear`), visible-cropped. Used to validate the shader by
/// readback, and as the fallback when Metal is unavailable.
public func jxlXYBToLinearPlanes(_ image: JXLXYBFloatImage) -> [[Float]] {
    let spec = OutputColorSpec.reconstruct(from: image.params)
    let state = ConvertState(spec)
    let n = image.width * image.height
    var r = [Float](repeating: 0, count: n)
    var g = r
    var b = r
    for i in 0..<n {
        let (lr, lg, lb) = state.linear(image.x[i], image.y[i], image.b[i])
        r[i] = lr
        g[i] = lg
        b[i] = lb
    }
    return [r, g, b]
}

extension OutputColorSpec {
    /// Rebuilds a spec from the shader params (linear conversion only — the
    /// transfer/quantizer fields are unused by `linear()`).
    fileprivate static func reconstruct(from p: JXLXYBColorParams) -> OutputColorSpec {
        let opsin = JXLOpsinInverseMatrix(
            inverseMatrix: p.opsinInverse,
            // ConvertState negates these back to positive biases.
            opsinBiases: p.opsinBias.map { -$0 },
            // Quant biases are unused by `linear()` (they apply to AC dequant).
            quantBiases: [0, 0, 0, 0])
        let ootf: (exponent: Float, lumR: Float, lumG: Float, lumB: Float)? =
            p.hlgOOTF.map { ($0.x, $0.y, $0.z, $0.w) }
        return OutputColorSpec(
            matrix: p.primariesMatrix, quantizer: TransferQuantizer(transfer: .linear),
            transfer: .linear, hlgOOTF: ootf, opsinScale: p.opsinScale,
            customOpsin: opsin)
    }
}

extension JXL {
    /// Decodes a lossy (XYB) still to pre-color-transform float XYB planes plus
    /// the parameters a GPU shader needs to finish the color conversion at draw
    /// time. Returns nil for frames the GPU display path does not cover (the
    /// caller then uses `decodeImage` + a CGImage).
    public static func decodeXYBForDisplay(
        from data: [UInt8], limits: JXLDecodeLimits = .default
    ) throws -> JXLXYBFloatImage? {
        try FrameDecoder(data: data, limits: limits).decodeXYBForDisplay()
    }

    public static func decodeXYBForDisplay(
        from data: Data, limits: JXLDecodeLimits = .default
    ) throws -> JXLXYBFloatImage? {
        try decodeXYBForDisplay(from: [UInt8](data), limits: limits)
    }
}
