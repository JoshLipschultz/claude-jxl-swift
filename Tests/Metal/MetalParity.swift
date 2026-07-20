// Headless GPU/CPU parity check for the Metal display-time color converter.
// Decodes a lossy fixture to XYB float, runs both the GPU converter and the
// CPU reference (jxlXYBToLinearPlanes), and reports max/relative error.
import Foundation
import JXLCore
import JXLKit

func rd(_ path: String) -> [UInt8] {
    (try? [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))) ?? []
}

let fixtures = CommandLine.arguments.dropFirst()
guard let converter = JXLMetalColorConverter() else {
    print("NO_METAL")
    exit(2)
}
print("device: \(converter.device.name)")

// Regression guard: out-of-range SIGNED samples must clamp, not wrap, in the
// display converter. A lossy alpha edge ringing to −1 once rendered as opaque
// (UInt32 bit-pattern wraparound) — black fringes around every transparent
// lossy edge.
do {
    let img = JXLDecodedImage(
        width: 2, height: 1, colorChannels: 3, extraChannels: 1,
        bitsPerSample: 8, isFloat: false,
        planes: [[300, 10], [-5, 10], [128, 10], [-1, 300]])  // R G B A
    let cg = try JXLImageConverter.makeCGImage(from: img)
    let raw = cg.dataProvider!.data! as Data
    // Pixel 0: alpha −1 → transparent (0), premultiplied color → 0.
    // Pixel 1: alpha 300 → opaque 255; color 10 stays 10.
    let got = [raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7]].map(Int.init)
    let want = [0, 0, 0, 0, 10, 10, 10, 255]
    guard got == want else {
        print("FAIL signed-clamp regression: got \(got) want \(want)")
        exit(1)
    }
    print("signed-clamp display conversion OK")
} catch {
    print("FAIL signed-clamp regression: \(error)")
    exit(1)
}

var worstAbs = 0.0
var anyRun = false
for path in fixtures {
    let bytes = rd(path)
    guard !bytes.isEmpty else { print("skip \(path): unreadable"); continue }
    guard let xyb = try? JXL.decodeXYBForDisplay(from: bytes) else {
        print("skip \((path as NSString).lastPathComponent): not an XYB fast-path frame")
        continue
    }
    // The XYB planes must agree with decodeImage's output geometry — this
    // catches decode-side bugs (e.g. cropping at pre-upsampling size) that
    // GPU-vs-CPU-linear comparison alone cannot, since both would consume the
    // same wrong planes.
    if let dec = try? JXL.decodeImage(from: bytes) {
        guard dec.width == xyb.width, dec.height == xyb.height else {
            print("FAIL \(path): XYB \(xyb.width)x\(xyb.height) != decodeImage \(dec.width)x\(dec.height)")
            exit(1)
        }
        if let a = xyb.alpha, a.count != xyb.width * xyb.height {
            print("FAIL \(path): alpha count \(a.count) != \(xyb.width * xyb.height)")
            exit(1)
        }
    }
    guard let gpu = converter.linearPlanes(from: xyb) else {
        print("FAIL \(path): GPU convert returned nil"); exit(1)
    }
    let cpu = jxlXYBToLinearPlanes(xyb)
    let n = xyb.width * xyb.height
    var maxAbs = 0.0
    var maxRel = 0.0
    var sumSq = 0.0
    for c in 0..<3 {
        for i in 0..<n {
            let a = Double(cpu[c][i])
            let b = Double(gpu[c][i])
            let d = abs(a - b)
            maxAbs = max(maxAbs, d)
            maxRel = max(maxRel, d / (abs(a) + 1e-6))
            sumSq += d * d
        }
    }
    let rms = (sumSq / Double(n * 3)).squareRoot()
    worstAbs = max(worstAbs, maxAbs)
    anyRun = true
    let name = (path as NSString).lastPathComponent
    print(String(
        format: "%@  %dx%d  maxAbs %.2e  maxRel %.2e  rms %.2e",
        name, xyb.width, xyb.height, maxAbs, maxRel, rms))
}
if !anyRun { print("no XYB fixtures ran"); exit(2) }
// Absolute error is the display-relevant metric: linear light is in [0, ~1+],
// so GPU vs CPU float32 (differing only by FMA/mul-order) sits at ~1e-5. The
// relative spikes are near-black values where 1e-6 abs is a huge ratio and
// invisible. Require < 1e-4 absolute.
print(worstAbs < 1e-4 ? "PARITY_OK (worst abs \(worstAbs))" : "PARITY_FAIL (worst abs \(worstAbs))")
exit(worstAbs < 1e-4 ? 0 : 1)
