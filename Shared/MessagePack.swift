import Foundation

/// Minimal MessagePack encoder/decoder covering only the wire subset
/// used by the pie engine's WebSocket protocol (see
/// `Vendor/pie/client/rust/src/message.rs`):
///
///   - positive integers (u8/u16/u32/u64, encoded as smallest variant)
///   - booleans
///   - UTF-8 strings (fixstr / str8 / str16 / str32)
///   - byte buffers (bin8 / bin16 / bin32)
///   - maps with string keys (fixmap / map16 / map32)
///   - arrays (fixarray / array16 / array32) — receive-side only
///
/// Pulling in a full MessagePack library would add ~3 KLOC of
/// generic-Codec machinery for the four message types we send and the
/// one shape we receive. The wire surface is tiny enough that
/// hand-rolling is cheaper than the dependency review.
///
/// Spec reference: https://github.com/msgpack/msgpack/blob/master/spec.md
public enum MessagePack {

  // MARK: - public value model

  /// On the wire pie sends/receives only this subset. Anything outside
  /// it is a protocol bug and `Decoder.decode` throws.
  public indirect enum Value: Equatable {
    case nil_
    case bool(Bool)
    case uint(UInt64)
    case int(Int64)
    case string(String)
    case binary(Data)
    case array([Value])
    case map([(Value, Value)])

    public static func == (lhs: Value, rhs: Value) -> Bool {
      switch (lhs, rhs) {
      case (.nil_, .nil_): return true
      case let (.bool(a), .bool(b)): return a == b
      case let (.uint(a), .uint(b)): return a == b
      case let (.int(a), .int(b)): return a == b
      case let (.uint(a), .int(b)): return b >= 0 && UInt64(b) == a
      case let (.int(a), .uint(b)): return a >= 0 && UInt64(a) == b
      case let (.string(a), .string(b)): return a == b
      case let (.binary(a), .binary(b)): return a == b
      case let (.array(a), .array(b)): return a == b
      case let (.map(a), .map(b)):
        guard a.count == b.count else { return false }
        for (l, r) in zip(a, b) where l != r { return false }
        return true
      default: return false
      }
    }
  }

  public enum DecodeError: Error, CustomStringConvertible {
    case truncated(at: Int, need: Int)
    case unsupported(tag: UInt8, at: Int)
    case invalidUTF8(at: Int)
    case trailingBytes(consumed: Int, total: Int)

    public var description: String {
      switch self {
      case let .truncated(at, need):
        return "msgpack truncated at offset \(at): need \(need) more bytes"
      case let .unsupported(tag, at):
        return "msgpack unsupported tag 0x\(String(tag, radix: 16)) at offset \(at)"
      case let .invalidUTF8(at):
        return "msgpack invalid UTF-8 at offset \(at)"
      case let .trailingBytes(consumed, total):
        return "msgpack trailing bytes after value: consumed=\(consumed) total=\(total)"
      }
    }
  }

  // MARK: - encode

  public static func encode(_ value: Value) -> Data {
    var out = Data()
    writeValue(value, into: &out)
    return out
  }

  private static func writeValue(_ value: Value, into out: inout Data) {
    switch value {
    case .nil_:
      out.append(0xc0)
    case let .bool(b):
      out.append(b ? 0xc3 : 0xc2)
    case let .uint(u):
      writeUInt(u, into: &out)
    case let .int(i):
      if i >= 0 { writeUInt(UInt64(i), into: &out) } else { writeNegInt(i, into: &out) }
    case let .string(s):
      writeString(s, into: &out)
    case let .binary(d):
      writeBinary(d, into: &out)
    case let .array(a):
      writeArrayHeader(a.count, into: &out)
      for item in a { writeValue(item, into: &out) }
    case let .map(kvs):
      writeMapHeader(kvs.count, into: &out)
      for (k, v) in kvs { writeValue(k, into: &out); writeValue(v, into: &out) }
    }
  }

  private static func writeUInt(_ u: UInt64, into out: inout Data) {
    if u <= 0x7f {
      out.append(UInt8(u))            // positive fixint
    } else if u <= UInt64(UInt8.max) {
      out.append(0xcc); out.append(UInt8(u))
    } else if u <= UInt64(UInt16.max) {
      out.append(0xcd); appendBigEndian(UInt16(u), into: &out)
    } else if u <= UInt64(UInt32.max) {
      out.append(0xce); appendBigEndian(UInt32(u), into: &out)
    } else {
      out.append(0xcf); appendBigEndian(u, into: &out)
    }
  }

  private static func writeNegInt(_ i: Int64, into out: inout Data) {
    if i >= -32 {
      out.append(UInt8(bitPattern: Int8(i)))   // negative fixint
    } else if i >= Int64(Int8.min) {
      out.append(0xd0); out.append(UInt8(bitPattern: Int8(i)))
    } else if i >= Int64(Int16.min) {
      out.append(0xd1); appendBigEndian(UInt16(bitPattern: Int16(i)), into: &out)
    } else if i >= Int64(Int32.min) {
      out.append(0xd2); appendBigEndian(UInt32(bitPattern: Int32(i)), into: &out)
    } else {
      out.append(0xd3); appendBigEndian(UInt64(bitPattern: i), into: &out)
    }
  }

  private static func writeString(_ s: String, into out: inout Data) {
    let bytes = Data(s.utf8)
    let n = bytes.count
    if n <= 31 {
      out.append(0xa0 | UInt8(n))     // fixstr
    } else if n <= Int(UInt8.max) {
      out.append(0xd9); out.append(UInt8(n))
    } else if n <= Int(UInt16.max) {
      out.append(0xda); appendBigEndian(UInt16(n), into: &out)
    } else {
      out.append(0xdb); appendBigEndian(UInt32(n), into: &out)
    }
    out.append(bytes)
  }

  private static func writeBinary(_ d: Data, into out: inout Data) {
    let n = d.count
    if n <= Int(UInt8.max) {
      out.append(0xc4); out.append(UInt8(n))
    } else if n <= Int(UInt16.max) {
      out.append(0xc5); appendBigEndian(UInt16(n), into: &out)
    } else {
      out.append(0xc6); appendBigEndian(UInt32(n), into: &out)
    }
    out.append(d)
  }

  private static func writeArrayHeader(_ n: Int, into out: inout Data) {
    if n <= 15 {
      out.append(0x90 | UInt8(n))
    } else if n <= Int(UInt16.max) {
      out.append(0xdc); appendBigEndian(UInt16(n), into: &out)
    } else {
      out.append(0xdd); appendBigEndian(UInt32(n), into: &out)
    }
  }

  private static func writeMapHeader(_ n: Int, into out: inout Data) {
    if n <= 15 {
      out.append(0x80 | UInt8(n))
    } else if n <= Int(UInt16.max) {
      out.append(0xde); appendBigEndian(UInt16(n), into: &out)
    } else {
      out.append(0xdf); appendBigEndian(UInt32(n), into: &out)
    }
  }

  private static func appendBigEndian(_ u: UInt16, into out: inout Data) {
    out.append(UInt8(u >> 8))
    out.append(UInt8(u & 0xff))
  }

  private static func appendBigEndian(_ u: UInt32, into out: inout Data) {
    for shift: UInt32 in [24, 16, 8, 0] { out.append(UInt8((u >> shift) & 0xff)) }
  }

  private static func appendBigEndian(_ u: UInt64, into out: inout Data) {
    for shift: UInt64 in [56, 48, 40, 32, 24, 16, 8, 0] {
      out.append(UInt8((u >> shift) & 0xff))
    }
  }

  // MARK: - decode

  public static func decode(_ data: Data) throws -> Value {
    var d = Decoder(data: data)
    let v = try d.readValue()
    if d.offset != data.count {
      throw DecodeError.trailingBytes(consumed: d.offset, total: data.count)
    }
    return v
  }

  private struct Decoder {
    let data: Data
    var offset: Int = 0

    mutating func need(_ n: Int) throws {
      if data.count - offset < n {
        throw DecodeError.truncated(at: offset, need: n - (data.count - offset))
      }
    }

    mutating func readByte() throws -> UInt8 {
      try need(1)
      let b = data[data.startIndex + offset]
      offset += 1
      return b
    }

    mutating func readBytes(_ n: Int) throws -> Data {
      try need(n)
      let start = data.startIndex + offset
      let slice = data.subdata(in: start ..< start + n)
      offset += n
      return slice
    }

    mutating func readU16BE() throws -> UInt16 {
      let bs = try readBytes(2)
      return (UInt16(bs[bs.startIndex]) << 8) | UInt16(bs[bs.startIndex + 1])
    }

    mutating func readU32BE() throws -> UInt32 {
      let bs = try readBytes(4)
      var u: UInt32 = 0
      for i in 0..<4 { u = (u << 8) | UInt32(bs[bs.startIndex + i]) }
      return u
    }

    mutating func readU64BE() throws -> UInt64 {
      let bs = try readBytes(8)
      var u: UInt64 = 0
      for i in 0..<8 { u = (u << 8) | UInt64(bs[bs.startIndex + i]) }
      return u
    }

    mutating func readValue() throws -> Value {
      let startOffset = offset
      let tag = try readByte()
      switch tag {
      case 0xc0: return .nil_
      case 0xc2: return .bool(false)
      case 0xc3: return .bool(true)
      // positive fixint
      case 0x00...0x7f: return .uint(UInt64(tag))
      // negative fixint
      case 0xe0...0xff: return .int(Int64(Int8(bitPattern: tag)))
      // fixstr
      case 0xa0...0xbf:
        let n = Int(tag & 0x1f)
        return .string(try readUTF8(n: n, at: startOffset))
      case 0xd9: let n = Int(try readByte());  return .string(try readUTF8(n: n, at: startOffset))
      case 0xda: let n = Int(try readU16BE()); return .string(try readUTF8(n: n, at: startOffset))
      case 0xdb: let n = Int(try readU32BE()); return .string(try readUTF8(n: n, at: startOffset))
      // uint
      case 0xcc: return .uint(UInt64(try readByte()))
      case 0xcd: return .uint(UInt64(try readU16BE()))
      case 0xce: return .uint(UInt64(try readU32BE()))
      case 0xcf: return .uint(try readU64BE())
      // int
      case 0xd0: return .int(Int64(Int8(bitPattern: try readByte())))
      case 0xd1: return .int(Int64(Int16(bitPattern: try readU16BE())))
      case 0xd2: return .int(Int64(Int32(bitPattern: try readU32BE())))
      case 0xd3: return .int(Int64(bitPattern: try readU64BE()))
      // bin
      case 0xc4: let n = Int(try readByte());  return .binary(try readBytes(n))
      case 0xc5: let n = Int(try readU16BE()); return .binary(try readBytes(n))
      case 0xc6: let n = Int(try readU32BE()); return .binary(try readBytes(n))
      // fixarray
      case 0x90...0x9f: return .array(try readArray(n: Int(tag & 0x0f)))
      case 0xdc: return .array(try readArray(n: Int(try readU16BE())))
      case 0xdd: return .array(try readArray(n: Int(try readU32BE())))
      // fixmap
      case 0x80...0x8f: return .map(try readMap(n: Int(tag & 0x0f)))
      case 0xde: return .map(try readMap(n: Int(try readU16BE())))
      case 0xdf: return .map(try readMap(n: Int(try readU32BE())))
      default:
        throw DecodeError.unsupported(tag: tag, at: startOffset)
      }
    }

    mutating func readUTF8(n: Int, at start: Int) throws -> String {
      let bs = try readBytes(n)
      guard let s = String(data: bs, encoding: .utf8) else {
        throw DecodeError.invalidUTF8(at: start)
      }
      return s
    }

    mutating func readArray(n: Int) throws -> [Value] {
      var out: [Value] = []
      out.reserveCapacity(n)
      for _ in 0..<n { out.append(try readValue()) }
      return out
    }

    mutating func readMap(n: Int) throws -> [(Value, Value)] {
      var out: [(Value, Value)] = []
      out.reserveCapacity(n)
      for _ in 0..<n {
        let k = try readValue()
        let v = try readValue()
        out.append((k, v))
      }
      return out
    }
  }
}

// MARK: - field helpers

extension MessagePack.Value {
  /// String-keyed lookup for response decoding. Returns nil when the
  /// value is not a map or the key is absent.
  public func field(_ key: String) -> MessagePack.Value? {
    guard case let .map(kvs) = self else { return nil }
    for (k, v) in kvs {
      if case let .string(sk) = k, sk == key { return v }
    }
    return nil
  }

  public var asString: String? {
    if case let .string(s) = self { return s }
    return nil
  }

  public var asBool: Bool? {
    if case let .bool(b) = self { return b }
    return nil
  }

  public var asUInt: UInt64? {
    switch self {
    case let .uint(u): return u
    case let .int(i) where i >= 0: return UInt64(i)
    default: return nil
    }
  }
}
