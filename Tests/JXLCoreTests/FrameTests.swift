import XCTest

@testable import JXLCore

final class FrameTests: XCTestCase {
    static let sizes: [(w: UInt32, h: UInt32)] = [
        (1, 1), (3, 5), (17, 1), (64, 48), (100, 100), (640, 480), (513, 257),
    ]
    static let variants = ["lossless", "lossy", "container"]

    func fixtureURL(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard
            let url = Bundle.module.url(
                forResource: base, withExtension: ext, subdirectory: "Fixtures")
        else {
            throw XCTSkip("fixture \(name) not bundled")
        }
        return url
    }

    func testFrameTocSectionRangesCoverPayload() throws {
        for (w, h) in Self.sizes {
            for variant in Self.variants {
                let name = "\(w)x\(h)_\(variant).jxl"
                let info = try JXL.readFrameInfo(contentsOf: fixtureURL(name))

                XCTAssertEqual(
                    info.dataStartByte + info.totalSectionBytes, info.codestreamLength,
                    "TOC sum invariant failed for \(name)")
                XCTAssertEqual(info.frameType, .regular, "expected regular frame for \(name)")
                XCTAssertEqual(
                    info.sectionSizes.count, info.tocEntryCount, "section count for \(name)")
                XCTAssertEqual(
                    info.sections.count, info.tocEntryCount, "section range count for \(name)")

                var totalRangeBytes = 0
                for section in info.sections {
                    XCTAssertEqual(
                        section.size, Int(info.sectionSizes[section.index]),
                        "section size mirrors TOC for \(name) section \(section.index)")
                    XCTAssertEqual(
                        section.codestreamRange.lowerBound, info.dataStartByte + section.offset,
                        "range start for \(name) section \(section.index)")
                    XCTAssertEqual(
                        section.codestreamRange.count, section.size,
                        "range size for \(name) section \(section.index)")
                    XCTAssertEqual(
                        section.role, expectedSectionRole(section.index, info),
                        "role for \(name) section \(section.index)")
                    XCTAssertEqual(
                        try JXL.readFrameSectionData(
                            contentsOf: fixtureURL(name), sectionIndex: section.index
                        ).count,
                        section.size,
                        "byte slice size for \(name) section \(section.index)")
                    XCTAssertEqual(
                        try JXL.readFrameSectionReader(
                            from: Data(contentsOf: fixtureURL(name)), sectionIndex: section.index
                        ).bitCount,
                        section.size * 8,
                        "reader size for \(name) section \(section.index)")
                    XCTAssertGreaterThanOrEqual(
                        section.codestreamRange.lowerBound, info.dataStartByte,
                        "section starts after TOC for \(name) section \(section.index)")
                    XCTAssertLessThanOrEqual(
                        section.codestreamRange.upperBound, info.codestreamLength,
                        "section ends inside codestream for \(name) section \(section.index)")
                    totalRangeBytes += section.size
                }
                XCTAssertEqual(
                    totalRangeBytes, info.totalSectionBytes, "section range total for \(name)")

                let physicalRanges = info.sections.map(\.codestreamRange).sorted {
                    $0.lowerBound < $1.lowerBound
                }
                var nextByte = info.dataStartByte
                for range in physicalRanges {
                    XCTAssertEqual(range.lowerBound, nextByte, "payload gap/overlap in \(name)")
                    nextByte = range.upperBound
                }
                XCTAssertEqual(nextByte, info.codestreamLength, "payload coverage for \(name)")
            }
        }
    }

    private func expectedSectionRole(_ index: Int, _ info: JXLFrameInfo) -> JXLFrameSectionRole {
        if info.numGroups == 1 && info.numPasses == 1 { return .singleSectionCoalesced }
        if index == 0 { return .dcGlobal }
        let acGlobalIndex = info.numDCGroups + 1
        if index < acGlobalIndex { return .dcGroup(index - 1) }
        if index == acGlobalIndex { return .acGlobal }
        let acIndex = index - acGlobalIndex - 1
        return .acGroup(pass: acIndex / info.numGroups, group: acIndex % info.numGroups)
    }

    func testFixtureEncodingModes() throws {
        let modular = try JXL.readFrameInfo(contentsOf: fixtureURL("64x48_lossless.jxl"))
        XCTAssertTrue(modular.isModular)

        let varDCT = try JXL.readFrameInfo(contentsOf: fixtureURL("513x257_lossy.jxl"))
        XCTAssertFalse(varDCT.isModular)
    }
}
