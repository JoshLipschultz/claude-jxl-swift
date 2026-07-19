// CustomTransformData.swift
//
// Structural parser for the codestream header's CustomTransformData bundle
// (libjxl `CustomTransformData::VisitFields`). This appears after
// ImageMetadata and before optional ICC/frame data. M4 only needs to consume it
// bit-exactly so frame headers and TOCs start at the correct position.

import Foundation

/// Custom upsampling kernel weights, when the file overrides the defaults
/// (UpsamplingWeights.swift). Each array is the triangular kernel half.
struct UpsamplingCustomWeights {
    var up2: [Float]?
    var up4: [Float]?
    var up8: [Float]?
}

/// A file's custom OpsinInverseMatrix (libjxl `OpsinInverseMatrix`): the
/// XYB→linear-RGB inverse absorbance matrix, per-channel opsin biases, and the
/// AC dequantization biases. Absent (`nil`) means the spec defaults.
struct JXLOpsinInverseMatrix {
    /// Row-major 3x3 inverse opsin absorbance matrix.
    var inverseMatrix: [Float]
    /// Per-channel opsin biases (default 0.0037930732552754493 each).
    var opsinBiases: [Float]
    /// AC quant biases: x, y, b, numerator (Reconstruct.adjustQuantBias).
    var quantBiases: [Float]
}

enum CustomTransformData {
    static func skip(_ reader: BitReader, xybEncoded: Bool) {
        _ = parse(reader, xybEncoded: xybEncoded)
    }

    static func parse(
        _ reader: BitReader, xybEncoded: Bool
    ) -> (weights: UpsamplingCustomWeights, opsin: JXLOpsinInverseMatrix?) {
        var weights = UpsamplingCustomWeights()
        if reader.readBool() { return (weights, nil) }  // all_default

        var opsin: JXLOpsinInverseMatrix? = nil
        if xybEncoded {
            opsin = parseOpsinInverseMatrix(reader)
        }

        let customWeightsMask = UInt32(reader.read(3))
        if (customWeightsMask & 0x1) != 0 {
            weights.up2 = (0..<15).map { _ in reader.readF16() }
        }
        if (customWeightsMask & 0x2) != 0 {
            weights.up4 = (0..<55).map { _ in reader.readF16() }
        }
        if (customWeightsMask & 0x4) != 0 {
            weights.up8 = (0..<210).map { _ in reader.readF16() }
        }
        // NOTE: libjxl's CustomTransformData::VisitFields has no extensions field;
        // it ends after the weight tables.
        return (weights, opsin)
    }

    private static func parseOpsinInverseMatrix(_ reader: BitReader) -> JXLOpsinInverseMatrix? {
        if reader.readBool() { return nil }  // all_default
        let matrix = (0..<9).map { _ in reader.readF16() }
        let biases = (0..<3).map { _ in reader.readF16() }
        let quant = (0..<4).map { _ in reader.readF16() }
        return JXLOpsinInverseMatrix(
            inverseMatrix: matrix, opsinBiases: biases, quantBiases: quant)
    }
}
