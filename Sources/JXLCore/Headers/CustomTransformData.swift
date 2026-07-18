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

enum CustomTransformData {
    static func skip(_ reader: BitReader, xybEncoded: Bool) {
        _ = parse(reader, xybEncoded: xybEncoded)
    }

    static func parse(_ reader: BitReader, xybEncoded: Bool) -> UpsamplingCustomWeights {
        var weights = UpsamplingCustomWeights()
        if reader.readBool() { return weights }  // all_default

        if xybEncoded {
            skipOpsinInverseMatrix(reader)
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
        return weights
    }

    private static func skipOpsinInverseMatrix(_ reader: BitReader) {
        if reader.readBool() { return }  // all_default

        // inverse_matrix[3][3], opsin_biases[3], quant_biases[4]
        for _ in 0..<16 { _ = reader.readF16() }
    }
}
