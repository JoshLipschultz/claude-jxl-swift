// JXLMetalColorConverter.swift
//
// Display-time color conversion on the GPU: takes a lossy frame's
// pre-color-transform XYB float planes (from `JXL.decodeXYBForDisplay`) and
// produces linear target-space RGB in an `MTLTexture` at draw time, running
// the opsin inverse + primaries matrix + HLG OOTF in a compute kernel. Linear
// output is what an extended-linear / EDR display path wants: the compositor
// applies the display transfer and HDR headroom.
//
// The kernel reproduces `ConvertState.linear` exactly (plain mul/add, no
// approximations), so a full-precision (rgba32Float) render read back matches
// the CPU reference `jxlXYBToLinearPlanes` to within GPU FMA rounding — which
// is how this path is validated headlessly.

#if canImport(Metal)
import CoreGraphics
import Metal
import JXLCore

/// A reusable GPU converter. One per `MTLDevice`; the pipeline is built once.
public final class JXLMetalColorConverter {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    /// Builds a converter on `device` (or the system default). Returns nil when
    /// Metal is unavailable or the kernel fails to compile.
    public init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice(),
            let queue = dev.makeCommandQueue()
        else { return nil }
        do {
            let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            guard let fn = lib.makeFunction(name: "xybToLinear") else { return nil }
            pipeline = try dev.makeComputePipelineState(function: fn)
        } catch {
            return nil
        }
        self.device = dev
        self.queue = queue
    }

    /// Renders `image` to a linear target-space RGBA texture (RGB = linear
    /// light, A = alpha). `pixelFormat` is `.rgba16Float` for display (ample
    /// precision, half the bandwidth) or `.rgba32Float` for exact readback.
    public func makeLinearTexture(
        from image: JXLXYBFloatImage, pixelFormat: MTLPixelFormat = .rgba16Float,
        usage: MTLTextureUsage = [.shaderRead], premultiply: Bool = false,
        displayMode: Float = 0
    ) -> MTLTexture? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        // Interleave XYB + alpha into an rgba32Float source texture.
        var src = [Float](repeating: 0, count: w * h * 4)
        let alpha = image.alpha
        for i in 0..<(w * h) {
            src[i * 4 + 0] = image.x[i]
            src[i * 4 + 1] = image.y[i]
            src[i * 4 + 2] = image.b[i]
            src[i * 4 + 3] = alpha?[i] ?? 1
        }
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        srcDesc.usage = [.shaderRead]
        guard let srcTex = device.makeTexture(descriptor: srcDesc) else { return nil }
        src.withUnsafeBytes { buf in
            srcTex.replace(
                region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                withBytes: buf.baseAddress!, bytesPerRow: w * 16)
        }

        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        dstDesc.usage = usage.union(.shaderWrite)
        guard let dstTex = device.makeTexture(descriptor: dstDesc) else { return nil }

        var params = Self.packParams(image.params)
        params.append(premultiply ? 1 : 0)
        params.append(displayMode)
        params.append(image.params.intensityTarget / 10000)
        guard let cmd = queue.makeCommandBuffer(),
            let enc = cmd.makeComputeCommandEncoder()
        else { return nil }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(dstTex, index: 1)
        enc.setBytes(&params, length: MemoryLayout<Float>.stride * params.count, index: 0)
        let tw = min(pipeline.threadExecutionWidth, w)
        let th = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tw, h))
        enc.dispatchThreads(
            MTLSize(width: w, height: h, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return dstTex
    }

    /// Renders to a full-precision texture and reads back the linear RGB
    /// planes. Used to validate the GPU path against the CPU reference, and as
    /// a headless converter when no drawable is involved.
    public func linearPlanes(from image: JXLXYBFloatImage) -> [[Float]]? {
        guard
            let tex = makeLinearTexture(
                from: image, pixelFormat: .rgba32Float, usage: [.shaderRead])
        else { return nil }
        let w = image.width
        let h = image.height
        var rgba = [Float](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            tex.getBytes(
                buf.baseAddress!, bytesPerRow: w * 16,
                from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var r = [Float](repeating: 0, count: w * h)
        var g = r
        var b = r
        for i in 0..<(w * h) {
            r[i] = rgba[i * 4 + 0]
            g[i] = rgba[i * 4 + 1]
            b[i] = rgba[i * 4 + 2]
        }
        return [r, g, b]
    }

    /// Renders `image` to a half-float `CGImage` in the frame's *extended
    /// linear* color space (linear light, EDR-friendly: the compositor applies
    /// the display transfer and headroom). The GPU produces the linear values;
    /// the system handles display encoding. Suitable for `layer.contents`.
    ///
    /// Returns nil for HDR transfers (PQ/HLG): mapping their absolute nits to
    /// extended-linear multiples of SDR white needs display-referred tuning
    /// that the CPU 16-bit + PQ/HLG-tagged path already handles correctly, so
    /// callers keep that path for HDR.
    public func makeLinearCGImage(from image: JXLXYBFloatImage) -> CGImage? {
        // Covered transfers: sRGB (13, or 0/2 rendered as sRGB), linear (8),
        // BT.709 (1), and — with 2020 primaries, where a named HDR colorspace
        // exists — PQ (16) and HLG (18), all encoded in-shader with the same
        // curves as the CPU 16-bit path. DCI/gamma and PQ/HLG on other
        // primaries fall back to the CPU converter.
        let tf = image.params.transferFunction
        let isHDR = tf == 16 || tf == 18
        if isHDR {
            guard image.params.primaries == 9 else { return nil }
        } else {
            guard tf == 0 || tf == 1 || tf == 2 || tf == 8 || tf == 13 else { return nil }
        }
        let mode: Float
        switch tf {
        case 1: mode = 2
        case 16: mode = 3
        case 18: mode = 4
        default: mode = 1
        }
        guard
            let tex = makeLinearTexture(
                from: image, pixelFormat: .rgba16Float, usage: [.shaderRead],
                premultiply: image.alpha != nil && !image.alphaPremultiplied,
                displayMode: mode)
        else { return nil }
        let w = image.width
        let h = image.height
        // Read back the half-float RGBA (2 bytes/component).
        var halfs = [UInt16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes { buf in
            tex.getBytes(
                buf.baseAddress!, bytesPerRow: w * 8,
                from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let name: CFString
        switch tf {
        case 1: name = CGColorSpace.itur_709
        case 16: name = CGColorSpace.itur_2100_PQ
        case 18: name = CGColorSpace.itur_2100_HLG
        default:
            switch image.params.primaries {
            case 11: name = CGColorSpace.extendedLinearDisplayP3
            case 9: name = CGColorSpace.extendedLinearITUR_2020
            default: name = CGColorSpace.extendedLinearSRGB
            }
        }
        guard let cs = CGColorSpace(name: name) else { return nil }
        // Premultiplied: scaling straight-alpha content bleeds transparent
        // pixels' (arbitrary) RGB into visible edges.
        let alphaInfo: CGImageAlphaInfo =
            image.alpha != nil ? .premultipliedLast : .last
        let bitmapInfo = CGBitmapInfo(
            rawValue: alphaInfo.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)
        let data = halfs.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: w * 8, space: cs, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// Packs the color params into the flat float buffer the kernel indexes.
    private static func packParams(_ p: JXLXYBColorParams) -> [Float] {
        var u = [Float](repeating: 0, count: 31)
        for i in 0..<9 { u[i] = p.opsinInverse[i] }
        for i in 0..<3 { u[9 + i] = p.opsinBiasCbrt[i] }
        for i in 0..<3 { u[12 + i] = p.opsinBias[i] }
        u[15] = p.opsinScale
        u[16] = p.primariesMatrix != nil ? 1 : 0
        u[17] = p.hlgOOTF != nil ? 1 : 0
        if let m = p.primariesMatrix {
            for i in 0..<9 { u[18 + i] = m[i] }
        }
        if let o = p.hlgOOTF {
            u[27] = o.x
            u[28] = o.y
            u[29] = o.z
            u[30] = o.w
        }
        return u
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        // Reproduces ConvertState.linear: XYB -> linear target-space RGB.
        kernel void xybToLinear(
            texture2d<float, access::read> src [[texture(0)]],
            texture2d<float, access::write> dst [[texture(1)]],
            constant float* u [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            float4 xyba = src.read(gid);
            float x = xyba.x, y = xyba.y, b = xyba.z;
            // Opsin inverse: gamma-decode, matrix, intensity scale.
            float gr = (y + x) + u[9];
            float gg = (y - x) + u[10];
            float gb = b + u[11];
            float mr = gr * gr * gr - u[12];
            float mg = gg * gg * gg - u[13];
            float mb = gb * gb * gb - u[14];
            float lr = u[0] * mr + u[1] * mg + u[2] * mb;
            float lg = u[3] * mr + u[4] * mg + u[5] * mb;
            float lb = u[6] * mr + u[7] * mg + u[8] * mb;
            float sc = u[15];
            lr *= sc; lg *= sc; lb *= sc;
            // Optional primaries matrix (linear-sRGB -> target).
            if (u[16] > 0.5) {
                float tr = u[18] * lr + u[19] * lg + u[20] * lb;
                float tg = u[21] * lr + u[22] * lg + u[23] * lb;
                float tb = u[24] * lr + u[25] * lg + u[26] * lb;
                lr = tr; lg = tg; lb = tb;
            }
            // Optional HLG inverse OOTF.
            if (u[17] > 0.5) {
                float lum = u[28] * lr + u[29] * lg + u[30] * lb;
                if (lum > 0.0) {
                    float ratio = min(pow(lum, u[27]), 1e9);
                    lr *= ratio; lg *= ratio; lb *= ratio;
                }
            }
            // Display modes (u[32]): 1 = clamp SDR linear to [0,1]
            // (extended-linear would carry DCT ringing outside the sRGB gamut
            // onto wide-gamut displays; the CPU path clamps at uint8);
            // 2 = clamp + BT.709 OETF (709 content is *displayed* through the
            // 1886-style convention; raw linear skips the intended OETF/EOTF
            // asymmetry); 3 = PQ encode (u[33] = intensity_target/10000,
            // domain [0, 10000/target] — mirrors OutputTransfer.encode);
            // 4 = HLG OETF (the inverse OOTF already ran above).
            int mode = int(u[32] + 0.5);
            if (mode == 1 || mode == 2 || mode == 4) {
                lr = clamp(lr, 0.0, 1.0);
                lg = clamp(lg, 0.0, 1.0);
                lb = clamp(lb, 0.0, 1.0);
            }
            if (mode == 2) {
                lr = lr < 0.018 ? 4.5 * lr : 1.099 * pow(lr, 0.45) - 0.099;
                lg = lg < 0.018 ? 4.5 * lg : 1.099 * pow(lg, 0.45) - 0.099;
                lb = lb < 0.018 ? 4.5 * lb : 1.099 * pow(lb, 0.45) - 0.099;
            } else if (mode == 3) {
                const float m1 = 2610.0 / 16384.0;
                const float m2 = (2523.0 / 4096.0) * 128.0;
                const float c1 = 3424.0 / 4096.0;
                const float c2 = (2413.0 / 4096.0) * 32.0;
                const float c3 = (2392.0 / 4096.0) * 32.0;
                float dmax = 1.0 / u[33];
                float3 v = clamp(float3(lr, lg, lb), 0.0, dmax) * u[33];
                float3 xp = pow(v, m1);
                float3 e = pow((c1 + xp * c2) / (1.0 + xp * c3), m2);
                lr = v.x == 0.0 ? 0.0 : e.x;
                lg = v.y == 0.0 ? 0.0 : e.y;
                lb = v.z == 0.0 ? 0.0 : e.z;
            } else if (mode == 4) {
                const float a = 0.17883277;
                const float b = 1.0 - 4.0 * a;
                const float c = 0.5 - a * log(4.0 * a);
                lr = lr == 0.0 ? 0.0 : (lr <= 1.0/12.0 ? sqrt(3.0 * lr) : a * log(12.0 * lr - b) + c);
                lg = lg == 0.0 ? 0.0 : (lg <= 1.0/12.0 ? sqrt(3.0 * lg) : a * log(12.0 * lg - b) + c);
                lb = lb == 0.0 ? 0.0 : (lb <= 1.0/12.0 ? sqrt(3.0 * lb) : a * log(12.0 * lb - b) + c);
            }
            // Premultiply for display when requested (u[31]), in the output
            // space (matching the CPU converter, which premultiplies the
            // encoded bytes).
            if (u[31] > 0.5) {
                lr *= xyba.w; lg *= xyba.w; lb *= xyba.w;
            }
            dst.write(float4(lr, lg, lb, xyba.w), gid);
        }
        """
}
#endif
