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

var worstAbs = 0.0
var anyRun = false
for path in fixtures {
    let bytes = rd(path)
    guard !bytes.isEmpty else { print("skip \(path): unreadable"); continue }
    guard let xyb = try? JXL.decodeXYBForDisplay(from: bytes) else {
        print("skip \((path as NSString).lastPathComponent): not an XYB fast-path frame")
        continue
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
