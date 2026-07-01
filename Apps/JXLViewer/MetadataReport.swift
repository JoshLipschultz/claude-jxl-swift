// MetadataReport.swift
//
// Builds the human-readable metadata report shown in the inspector panel, using
// only the decoder's introspection APIs (readInfo / readFrameInfo /
// readVarDCTInfo). This is the GUI counterpart to the `jxl info` and
// `jxl vardct` CLI commands. Every step is best-effort: a section that can't be
// parsed is simply annotated, never fatal.

import Foundation
import JXLCore

enum MetadataReport {

    static func build(from data: Data) -> String {
        var lines: [String] = []

        // --- Image metadata (always available for a valid file) ---
        do {
            let info = try JXL.readInfo(from: data)
            lines.append("IMAGE")
            lines.append("  dimensions   \(info.width) × \(info.height)")
            lines.append("  sample       \(sampleDescription(info.bitDepth))")
            lines.append("  color space  \(colorSpaceName(info.colorSpace))")
            lines.append("  channels     \(info.colorChannelCount) color + \(info.extraChannelCount) extra")
            lines.append("  alpha        \(info.hasAlpha ? "yes" : "no")")
            lines.append("  orientation  \(info.orientation)")
            lines.append("  animation    \(info.hasAnimation ? "yes" : "no")")
            lines.append("  container    \(info.isContainer ? "yes" : "no")")

            lines.append("")
            lines.append("COLOR ENCODING")
            let ce = info.colorEncoding
            if ce.wantICC {
                lines.append("  ICC profile (embedded)")
            } else {
                let transfer = ce.hasGamma ? "gamma \(ce.gamma)" : "transfer fn \(ce.transferFunction)"
                lines.append("  white point  \(ce.whitePoint)")
                lines.append("  primaries    \(ce.primaries)")
                lines.append("  transfer     \(transfer)")
                lines.append("  intent       \(ce.renderingIntent)")
            }

            if !info.boxTypes.isEmpty {
                lines.append("")
                lines.append("CONTAINER BOXES")
                lines.append("  " + info.boxTypes.joined(separator: ", "))
            }
        } catch {
            return "Could not read image metadata:\n  \(error)"
        }

        // --- Frame + TOC structure ---
        if let frame = try? JXL.readFrameInfo(from: data) {
            lines.append("")
            lines.append("FRAME")
            lines.append("  mode         \(frame.isModular ? "Modular (lossless)" : "VarDCT (lossy)")")
            lines.append("  type         \(frame.frameType)")
            lines.append("  passes       \(frame.numPasses)")
            lines.append("  groups       \(frame.numGroups)  (DC groups \(frame.numDCGroups))")
            lines.append("  last frame   \(frame.isLast ? "yes" : "no")")

            lines.append("")
            lines.append("TOC SECTIONS (\(frame.sections.count))")
            for section in frame.sections.prefix(64) {
                lines.append("  [\(section.index)] \(roleName(section.role))  \(section.size) B")
            }
            if frame.sections.count > 64 {
                lines.append("  … \(frame.sections.count - 64) more")
            }

            // --- VarDCT globals, when this is a lossy frame we can preflight ---
            if !frame.isModular {
                lines.append("")
                lines.append("VARDCT GLOBALS")
                if let v = try? JXL.readVarDCTInfo(from: data) {
                    let q = v.dcGlobal.quantizer
                    lines.append("  global scale \(q.globalScale)")
                    lines.append("  quant DC     \(q.quantDC)")
                    lines.append("  DC quant     \(v.dcGlobal.dcQuantIsDefault ? "default" : "custom")")
                    let bc = v.dcGlobal.blockContextMap
                    lines.append("  block ctx    \(bc.numContexts) (\(bc.numDCContexts) DC)")
                    if let ac = v.acGlobal {
                        lines.append("  AC dequant   \(ac.dequantMatricesAreDefault ? "default" : "custom")")
                        lines.append("  AC histograms \(ac.numHistograms)")
                    } else {
                        lines.append("  AC global    coalesced in single section")
                    }
                } else {
                    lines.append("  (could not preflight — unsupported globals)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    private static func sampleDescription(_ bitDepth: JXLBitDepth) -> String {
        if bitDepth.isFloatingPoint {
            return "\(bitDepth.bitsPerSample)-bit float (\(bitDepth.exponentBitsPerSample) exp bits)"
        }
        return "\(bitDepth.bitsPerSample)-bit integer"
    }

    private static func colorSpaceName(_ space: JXLColorSpace) -> String {
        switch space {
        case .rgb: return "RGB"
        case .grayscale: return "Grayscale"
        case .xyb: return "XYB"
        case .unknown: return "Unknown"
        }
    }

    private static func roleName(_ role: JXLFrameSectionRole) -> String {
        switch role {
        case .singleSectionCoalesced: return "all (coalesced)"
        case .dcGlobal: return "DC-global"
        case .dcGroup(let g): return "DC-group \(g)"
        case .acGlobal: return "AC-global"
        case .acGroup(let pass, let group): return "AC-group p\(pass) g\(group)"
        }
    }
}
