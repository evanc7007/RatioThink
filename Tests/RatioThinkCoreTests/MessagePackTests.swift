import XCTest
@testable import RatioThinkCore

/// Wire-format unit tests for `Shared/MessagePack.swift`. The encoder
/// is the wire authority binding to the Rust schema at
/// `Vendor/pie/client/rust/src/message.rs`; PieControlClient's
/// framing depends on its correctness for `auth_by_token`,
/// `add_program` (chunked), and `launch_daemon`. A round-trip drift
/// here would surface only in end-to-end S0 — these tests catch it
/// inside the unit suite (review  F3).
final class MessagePackTests: XCTestCase {

  // MARK: - round-trip

  func test_roundTripPrimitives() throws {
    let cases: [MessagePack.Value] = [
      .nil_, .bool(true), .bool(false),
      .uint(0), .uint(1), .uint(127), .uint(128), .uint(255), .uint(256), .uint(65535), .uint(65536),
      .uint(0xFFFF_FFFF), .uint(0x1_0000_0000), .uint(UInt64.max),
      .int(-1), .int(-32), .int(-33), .int(-128), .int(-129),
      .int(Int64(Int16.min)), .int(Int64(Int16.min) - 1),
      .int(Int64(Int32.min)), .int(Int64(Int32.min) - 1), .int(Int64.min),
      .string(""), .string("ok"), .string("héllo"),
      .binary(Data()), .binary(Data([0x00, 0xff, 0xab, 0xcd])),
    ]
    for value in cases {
      let bytes = MessagePack.encode(value)
      let decoded = try MessagePack.decode(bytes)
      XCTAssertEqual(decoded, value, "round-trip mismatch for \(value)")
    }
  }

  // MARK: - string length boundaries

  func test_stringEncodingBoundaries_fixstrToStr32() throws {
    // fixstr accepts up to 31 bytes; 32 spills to str8.
    let s31 = String(repeating: "a", count: 31)
    let s32 = String(repeating: "a", count: 32)
    XCTAssertEqual(MessagePack.encode(.string(s31)).first, 0xa0 | 31, "31-byte string must use fixstr (0xbf)")
    XCTAssertEqual(MessagePack.encode(.string(s32)).first, 0xd9, "32-byte string must spill to str8 (0xd9)")
    XCTAssertEqual(try MessagePack.decode(MessagePack.encode(.string(s32))), .string(s32))

    // str8 → str16 at 256 bytes.
    let s255 = String(repeating: "b", count: 255)
    let s256 = String(repeating: "b", count: 256)
    XCTAssertEqual(MessagePack.encode(.string(s255)).first, 0xd9)
    XCTAssertEqual(MessagePack.encode(.string(s256)).first, 0xda, "256-byte string must spill to str16 (0xda)")
    XCTAssertEqual(try MessagePack.decode(MessagePack.encode(.string(s256))), .string(s256))

    // str16 → str32 at 65536 bytes.
    let s65535 = String(repeating: "c", count: 65535)
    let s65536 = String(repeating: "c", count: 65536)
    XCTAssertEqual(MessagePack.encode(.string(s65535)).first, 0xda)
    XCTAssertEqual(MessagePack.encode(.string(s65536)).first, 0xdb,
                   "65536-byte string must spill to str32 (0xdb)")
    XCTAssertEqual(try MessagePack.decode(MessagePack.encode(.string(s65536))), .string(s65536))
  }

  // MARK: - binary length boundaries

  func test_binaryEncodingBoundaries_bin8_bin16_bin32() throws {
    let b255 = Data(repeating: 0xab, count: 255)
    let b256 = Data(repeating: 0xab, count: 256)
    let b64k = Data(repeating: 0xcd, count: 65535)
    let b64kPlus = Data(repeating: 0xcd, count: 65536)

    XCTAssertEqual(MessagePack.encode(.binary(b255)).first, 0xc4, "≤ UInt8.max bytes must use bin8 (0xc4)")
    XCTAssertEqual(MessagePack.encode(.binary(b256)).first, 0xc5, "256 bytes must spill to bin16 (0xc5)")
    XCTAssertEqual(MessagePack.encode(.binary(b64k)).first, 0xc5)
    XCTAssertEqual(MessagePack.encode(.binary(b64kPlus)).first, 0xc6,
                   "65536 bytes must spill to bin32 (0xc6)")
    XCTAssertEqual(try MessagePack.decode(MessagePack.encode(.binary(b256))), .binary(b256))
    XCTAssertEqual(try MessagePack.decode(MessagePack.encode(.binary(b64kPlus))), .binary(b64kPlus))
  }

  // MARK: - map round-trip + field accessor

  func test_mapRoundTripAndFieldAccessor() throws {
    // Mirror the `add_program` request shape PieControlClient emits.
    let msg: MessagePack.Value = .map([
      (.string("type"),            .string("add_program")),
      (.string("corr_id"),         .uint(42)),
      (.string("program_hash"),    .string("deadbeef")),
      (.string("manifest"),        .string("[runtime]\ncore = \"^0.2.0\"\n")),
      (.string("force_overwrite"), .bool(true)),
      (.string("chunk_index"),     .uint(0)),
      (.string("total_chunks"),    .uint(1)),
      (.string("chunk_data"),      .binary(Data([0x00, 0x61, 0x73, 0x6d]))),
    ])
    let bytes = MessagePack.encode(msg)
    let decoded = try MessagePack.decode(bytes)
    XCTAssertEqual(decoded, msg)

    XCTAssertEqual(decoded.field("type")?.asString, "add_program")
    XCTAssertEqual(decoded.field("corr_id")?.asUInt, 42)
    XCTAssertEqual(decoded.field("force_overwrite")?.asBool, true)
    XCTAssertNil(decoded.field("not_present"))
  }

  // MARK: - array

  func test_arrayBoundaries() throws {
    let small: MessagePack.Value = .array((0..<15).map { .uint(UInt64($0)) })
    XCTAssertEqual(MessagePack.encode(small).first, 0x9f, "15-element array must use fixarray (0x9f)")
    let med: MessagePack.Value = .array((0..<16).map { .uint(UInt64($0)) })
    XCTAssertEqual(MessagePack.encode(med).first, 0xdc, "16-element array must spill to array16 (0xdc)")
    XCTAssertEqual(try MessagePack.decode(MessagePack.encode(med)), med)
  }

  // MARK: - decoder safety

  func test_decodeFailsOnTruncatedFrame() {
    // `str16` header advertises 5 bytes but only 3 follow.
    let truncated = Data([0xda, 0x00, 0x05, 0x61, 0x62, 0x63])
    XCTAssertThrowsError(try MessagePack.decode(truncated)) { err in
      guard case MessagePack.DecodeError.truncated = err else {
        XCTFail("expected DecodeError.truncated, got \(err)"); return
      }
    }
  }

  func test_decodeFailsOnTrailingBytes() {
    // A valid `true` (0xc3) followed by extra bytes the parser is
    // not asked to consume.
    let trailing = Data([0xc3, 0x00])
    XCTAssertThrowsError(try MessagePack.decode(trailing)) { err in
      guard case MessagePack.DecodeError.trailingBytes = err else {
        XCTFail("expected DecodeError.trailingBytes, got \(err)"); return
      }
    }
  }

  func test_decodeRejectsInvalidUTF8() {
    // fixstr len=2, body=0xff 0xff (invalid UTF-8).
    let frame = Data([0xa2, 0xff, 0xff])
    XCTAssertThrowsError(try MessagePack.decode(frame)) { err in
      guard case MessagePack.DecodeError.invalidUTF8 = err else {
        XCTFail("expected DecodeError.invalidUTF8, got \(err)"); return
      }
    }
  }
}
