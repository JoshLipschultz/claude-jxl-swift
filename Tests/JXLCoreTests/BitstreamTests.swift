import XCTest
@testable import JXLCore

final class BitstreamTests: XCTestCase {

    func testReadLSBFirst() {
        // 0b1011_0010 = 0xB2. LSB-first reads: bit0=0, then ...
        let r = BitReader([0xB2])
        XCTAssertEqual(r.read(1), 0)        // bit0
        XCTAssertEqual(r.read(1), 1)        // bit1
        XCTAssertEqual(r.read(2), 0)        // bits2-3 = 00
        XCTAssertEqual(r.read(4), 0b1011)   // bits4-7
        XCTAssertTrue(r.isAtEnd)
    }

    func testReadAcrossByteBoundary() {
        // bytes 0x01 0x00 -> reading 16 bits LSB-first yields 0x0001
        let r = BitReader([0x01, 0x00])
        XCTAssertEqual(r.read(16), 0x0001)
        // 0xFF 0x0A signature read as 16 bits LSB-first:
        let s = BitReader([0xFF, 0x0A])
        XCTAssertEqual(s.read(16), 0x0AFF)
    }

    func testOverreadYieldsZeroAndLatches() {
        let r = BitReader([0xFF])
        XCTAssertEqual(r.read(8), 0xFF)
        XCTAssertFalse(r.didOverread)
        XCTAssertEqual(r.read(8), 0) // past end
        XCTAssertTrue(r.didOverread)
    }

    func testU64KnownVectors() {
        // selector 0 -> 0
        XCTAssertEqual(BitReader([0b0000_0000]).readU64(), 0)
        // selector 1 (bits 0-1 = 01) then u(4). Byte 0b0_0101_01:
        //   bit0=1,bit1=0 -> selector=01b=1; next 4 bits = bits2..5.
        //   0b00_0101_01: bits LSB->MSB: 1,0,1,0,1,0,0,0 => u(4)=bits2-5=1,0,1,0 =0b0101=5 -> 5+1=6
        XCTAssertEqual(BitReader([0b0001_0101]).readU64(), 6)
    }

    func testU32Selector() {
        // selector bits first (2 bits). Choose distribution 2 = bits(4, offset: 2).
        // byte: selector=10b (bit0=0,bit1=1) then read(4).
        // 0b00_0011_10: bit0=0,bit1=1 -> sel=0b10=2; bits2-5 = 1,1,0,0 = 0b0011 = 3; +offset2 = 5
        let r = BitReader([0b0000_1110])
        let v = r.readU32(.value(0), .value(1), .bits(4, offset: 2), .bits(8))
        XCTAssertEqual(v, 5)
    }

    func testF16() {
        // 0x3C00 = 1.0, 0xC000 = -2.0, 0x0000 = 0.0
        XCTAssertEqual(Float(float16Bits: 0x3C00), 1.0)
        XCTAssertEqual(Float(float16Bits: 0xC000), -2.0)
        XCTAssertEqual(Float(float16Bits: 0x0000), 0.0)
        XCTAssertEqual(Float(float16Bits: 0x3555), 0.333251953125, accuracy: 1e-6)
    }
}
