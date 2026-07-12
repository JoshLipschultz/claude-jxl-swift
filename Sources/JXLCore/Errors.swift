// Errors.swift
//
// Error type shared across the decoder.

import Foundation

/// Errors thrown while parsing or decoding a JPEG XL stream.
public enum JXLError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The data does not begin with a recognized JPEG XL signature
    /// (neither the raw codestream `FF 0A` nor the ISOBMFF container box).
    case invalidSignature

    /// The stream ended before a required field could be read.
    case truncated(context: String)

    /// A construct that is valid per the spec but not yet implemented by this decoder.
    case unsupported(String)

    /// The stream is structurally invalid (violates the spec).
    case malformed(String)

    /// The image is valid but exceeds the caller's `JXLDecodeLimits` (e.g. a
    /// header claiming enormous dimensions). Guards against decode bombs when
    /// parsing untrusted files.
    case limitExceeded(String)

    public var description: String {
        switch self {
        case .invalidSignature:
            return "Not a JPEG XL file (no codestream or container signature)."
        case .truncated(let ctx):
            return "Unexpected end of stream while reading \(ctx)."
        case .unsupported(let what):
            return "Unsupported JPEG XL feature: \(what)."
        case .malformed(let why):
            return "Malformed JPEG XL stream: \(why)."
        case .limitExceeded(let what):
            return "JPEG XL image exceeds decode limits: \(what)."
        }
    }
}
