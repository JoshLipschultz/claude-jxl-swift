// CustomTransformData.swift
//
// Structural parser for the codestream header's CustomTransformData bundle
// (libjxl `CustomTransformData::VisitFields`). This appears after
// ImageMetadata and before optional ICC/frame data. M4 only needs to consume it
// bit-exactly so frame headers and TOCs start at the correct position.

import Foundation

enum CustomTransformData {
    static func skip(_ reader: BitReader, xybEncoded: Bool) {
        if reader.readBool() { return }  // all_default

        if xybEncoded {
            skipOpsinInverseMatrix(reader)
        }

        let customWeightsMask = UInt32(reader.read(3))
        if (customWeightsMask & 0x1) != 0 {
            for _ in 0..<15 { _ = reader.readF16() }
        }
        if (customWeightsMask & 0x2) != 0 {
            for _ in 0..<55 { _ = reader.readF16() }
        }
        if (customWeightsMask & 0x4) != 0 {
            for _ in 0..<210 { _ = reader.readF16() }
        }
        // NOTE: libjxl's CustomTransformData::VisitFields has no extensions field;
        // it ends after the weight tables.
    }

    private static func skipOpsinInverseMatrix(_ reader: BitReader) {
        if reader.readBool() { return }  // all_default

        // inverse_matrix[3][3], opsin_biases[3], quant_biases[4]
        for _ in 0..<16 { _ = reader.readF16() }
    }
}
