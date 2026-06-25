// Transforms.swift
//
// Inverse Modular transforms (libjxl modular/transform/*). Transforms are undone
// in reverse order after the channels are decoded. So far: the reversible color
// transform (RCT, 42 types = 6 permutations × 7 mixings, incl. YCoCg).
// Palette and Squeeze undo are not yet implemented.

import Foundation

/// Undoes the transforms applied to a decoded Modular image, in reverse order.
func undoTransforms(_ image: ModularImage, transforms: [ModularTransform]) throws {
    for t in transforms.reversed() {
        switch t.id {
        case .rct:
            invRCT(image, beginC: Int(t.beginC), rctType: Int(t.rctType))
        default:
            throw ModularDecodeError.unsupportedTransform
        }
    }
}

/// Inverse reversible color transform (libjxl InvRCT).
func invRCT(_ image: ModularImage, beginC m: Int, rctType: Int) {
    if rctType == 0 { return }
    let permutation = rctType / 7
    let custom = rctType % 7
    let w = image.channels[m].w
    let h = image.channels[m].h

    // Output channel positions after the permutation.
    let o0 = m + (permutation % 3)
    let o1 = m + ((permutation + 1 + permutation / 3) % 3)
    let o2 = m + ((permutation + 2 - permutation / 3) % 3)

    if custom == 0 {
        // Permute-only: move the three planes into their output positions.
        let c0 = image.channels[m]
        let c1 = image.channels[m + 1]
        let c2 = image.channels[m + 2]
        image.channels[o0] = c0
        image.channels[o1] = c1
        image.channels[o2] = c2
        return
    }

    let second = custom >> 1
    let third = custom & 1
    for y in 0..<h {
        for x in 0..<w {
            // Read all three inputs first (output planes may alias inputs).
            let inA = Int(image.channels[m].at(x, y))
            let inB = Int(image.channels[m + 1].at(x, y))
            let inC = Int(image.channels[m + 2].at(x, y))
            let r0: Int
            let r1: Int
            let r2: Int
            if custom == 6 {  // YCoCg
                let tmp = inA - (inC >> 1)  // Y - (Cg>>1)
                let g = inC + tmp
                let b = tmp - (inB >> 1)  // tmp - (Co>>1)
                r0 = b + inB  // R = B + Co
                r1 = g
                r2 = b
            } else {
                var first = inA
                var sec = inB
                var thd = inC
                if third == 1 { thd = thd &+ first }
                if second == 1 {
                    sec = sec &+ first
                } else if second == 2 {
                    sec = sec &+ ((first &+ thd) >> 1)
                }
                first = inA
                r0 = first
                r1 = sec
                r2 = thd
            }
            image.channels[o0].set(x, y, Int32(truncatingIfNeeded: r0))
            image.channels[o1].set(x, y, Int32(truncatingIfNeeded: r1))
            image.channels[o2].set(x, y, Int32(truncatingIfNeeded: r2))
        }
    }
}
