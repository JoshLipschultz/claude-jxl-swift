// ModularImage.swift
//
// The in-memory representation Modular mode decodes into (libjxl
// modular_image.h): an `Image` is a list of `Channel`s, each a 2-D plane of
// 32-bit signed samples. Transforms can change the number and shape of
// channels, so channels carry their own width/height and subsampling shifts.

import Foundation

struct ModularChannel {
    var w: Int
    var h: Int
    var hshift: Int
    var vshift: Int
    /// Row-major `w * h` samples.
    var pixels: [Int32]

    init(w: Int, h: Int, hshift: Int = 0, vshift: Int = 0) {
        self.w = w
        self.h = h
        self.hshift = hshift
        self.vshift = vshift
        self.pixels = [Int32](repeating: 0, count: max(0, w * h))
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Int32 { pixels[y * w + x] }
    @inline(__always) mutating func set(_ x: Int, _ y: Int, _ v: Int32) { pixels[y * w + x] = v }
}

final class ModularImage {
    var channels: [ModularChannel]
    var nbMetaChannels: Int = 0
    var w: Int
    var h: Int
    var bitdepth: Int

    init(w: Int, h: Int, bitdepth: Int, channelCount: Int) {
        self.w = w
        self.h = h
        self.bitdepth = bitdepth
        self.channels = (0..<channelCount).map { _ in ModularChannel(w: w, h: h) }
    }
}
