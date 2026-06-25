// MATree.swift
//
// The meta-adaptive (MA) decision tree used by Modular mode (libjxl dec_ma.cc).
// The tree is itself entropy-coded — decoding it is the first place the M3 ANS
// engine runs on real codestream data. Each internal node tests
// `property > splitVal` (left) vs `<= splitVal` (right); each leaf carries a
// predictor, an additive offset, and a multiplier applied to the residual.

import Foundation

struct MATreeNode: Equatable {
    var property: Int  // -1 for a leaf
    var splitVal: Int32
    var lchild: Int  // for a leaf, the leaf id
    var rchild: Int
    var predictor: Int  // Predictor enum value (0...13)
    var predictorOffset: Int64
    var multiplier: UInt32

    var isLeaf: Bool { property == -1 }
}

/// Inverse of libjxl's `PackSigned` (maps unsigned to signed, LSB = sign).
@inline(__always)
func unpackSigned(_ u: UInt32) -> Int64 {
    let v = UInt64(u)
    return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
}

private let kNumModularPredictors = 14

// MATreeContext (ma_common.h).
private let kSplitValContext = 0
private let kPropertyContext = 1
private let kPredictorContext = 2
private let kOffsetContext = 3
private let kMultiplierLogContext = 4
private let kMultiplierBitsContext = 5
private let kNumTreeContexts = 6

/// Decodes a meta-adaptive decision tree (libjxl `DecodeTree`): reads its own
/// entropy-code header, decodes the node list, and verifies the final ANS
/// state. Returns nil on malformed input.
func decodeMATree(_ br: BitReader, treeSizeLimit: Int) -> [MATreeNode]? {
    guard let (code, contextMap) = decodeHistograms(br, numContexts: kNumTreeContexts, disallowLZ77: false)
    else { return nil }
    let reader = ANSSymbolReader(code: code, reader: br)

    var tree = [MATreeNode]()
    var leafID = 0
    var toDecode = 1
    while toDecode > 0 {
        if !br.allReadsWithinBounds { return nil }
        if tree.count > treeSizeLimit { return nil }
        toDecode -= 1

        let prop1 = reader.readHybridUint(kPropertyContext, br, contextMap: contextMap)
        if prop1 > 256 { return nil }
        let property = Int(prop1) - 1

        if property == -1 {
            let predictor = reader.readHybridUint(kPredictorContext, br, contextMap: contextMap)
            if predictor >= UInt32(kNumModularPredictors) { return nil }
            let predictorOffset = unpackSigned(
                reader.readHybridUint(kOffsetContext, br, contextMap: contextMap))
            let mulLog = reader.readHybridUint(kMultiplierLogContext, br, contextMap: contextMap)
            if mulLog >= 31 { return nil }
            let mulBits = reader.readHybridUint(kMultiplierBitsContext, br, contextMap: contextMap)
            if mulBits >= (UInt32(1) << (31 - mulLog)) - 1 { return nil }
            let multiplier = (mulBits + 1) << mulLog
            tree.append(
                MATreeNode(
                    property: -1, splitVal: 0, lchild: leafID, rchild: 0,
                    predictor: Int(predictor), predictorOffset: predictorOffset,
                    multiplier: multiplier))
            leafID += 1
            continue
        }

        let splitVal = Int32(
            truncatingIfNeeded: unpackSigned(
                reader.readHybridUint(kSplitValContext, br, contextMap: contextMap)))
        tree.append(
            MATreeNode(
                property: property, splitVal: splitVal,
                lchild: tree.count + toDecode + 1, rchild: tree.count + toDecode + 2,
                predictor: 0, predictorOffset: 0, multiplier: 1))
        toDecode += 2
    }

    if !reader.checkANSFinalState() { return nil }
    return tree
}
