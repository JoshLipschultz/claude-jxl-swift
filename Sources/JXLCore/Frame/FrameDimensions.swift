// FrameDimensions.swift
//
// Derives the group / DC-group grid for a frame from its pixel size and
// `group_size_shift` (libjxl frame_dimensions.h / toc.h). These counts drive
// how many sections the TOC has.

import Foundation

let kBlockDim = 8
let kGroupDim = 256

@inline(__always)
func divCeil(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }

public struct FrameDimensions: Equatable, Sendable {
    public var xsize = 0
    public var ysize = 0
    public var xsizeBlocks = 0
    public var ysizeBlocks = 0
    public var xsizeGroups = 0
    public var ysizeGroups = 0
    public var xsizeDCGroups = 0
    public var ysizeDCGroups = 0
    public var numGroups = 0
    public var numDCGroups = 0
    public var groupDim = 0
    public var dcGroupDim = 0

    /// Mirrors `FrameDimensions::Set`.
    public mutating func set(
        xsize xs: Int, ysize ys: Int, groupSizeShift: Int,
        maxHShift: Int, maxVShift: Int, modular: Bool, upsampling: Int
    ) {
        groupDim = (kGroupDim >> 1) << groupSizeShift
        dcGroupDim = groupDim * kBlockDim
        xsize = divCeil(xs, upsampling)
        ysize = divCeil(ys, upsampling)
        xsizeBlocks = divCeil(xsize, kBlockDim << maxHShift) << maxHShift
        ysizeBlocks = divCeil(ysize, kBlockDim << maxVShift) << maxVShift
        xsizeGroups = divCeil(xsize, groupDim)
        ysizeGroups = divCeil(ysize, groupDim)
        xsizeDCGroups = divCeil(xsizeBlocks, groupDim)
        ysizeDCGroups = divCeil(ysizeBlocks, groupDim)
        numGroups = xsizeGroups * ysizeGroups
        numDCGroups = xsizeDCGroups * ysizeDCGroups
    }
}

/// Index of the first AC (PassGroup) section (toc.h `AcGroupIndex`).
func acGroupIndex(pass: Int, group: Int, numGroups: Int, numDCGroups: Int) -> Int {
    2 + numDCGroups + pass * numGroups + group
}

/// Number of TOC sections for a frame (toc.h `NumTocEntries`).
func numTocEntries(numGroups: Int, numDCGroups: Int, numPasses: Int) -> Int {
    if numGroups == 1 && numPasses == 1 { return 1 }
    return acGroupIndex(pass: 0, group: 0, numGroups: numGroups, numDCGroups: numDCGroups)
        + numGroups * numPasses
}
