//! attributedBody (typedstream) decoder for iMessage.
//!
//! On macOS Ventura+, Messages.app may store message text only in the
//! `attributedBody` BLOB column (NSAttributedString archived via
//! NSKeyedArchiver / typedstream). The plain `text` column is NULL in
//! these cases.
//!
//! This module extracts the UTF-8 string payload from the binary blob
//! without depending on Foundation or ObjC runtime.

const std = @import("std");

/// Marker bytes preceding the UTF-8 string payload in a typedstream
/// attributedBody blob.
const MARKER = [_]u8{ 0x84, 0x01, 0x2b };

/// Decode the UTF-8 text from an iMessage `attributedBody` BLOB.
///
/// Returns a slice into `blob` on success, or null if the blob is
/// missing, empty, or doesn't contain a recognisable payload.
pub fn decodeAttributedBody(blob: ?[]const u8) ?[]const u8 {
    const data = blob orelse return null;
    if (data.len < MARKER.len + 2) return null;

    // Scan for the marker sequence.
    const marker_pos = std.mem.indexOf(u8, data, &MARKER) orelse return null;
    const after_marker = marker_pos + MARKER.len;
    if (after_marker >= data.len) return null;

    // Read length encoding.
    const len_byte = data[after_marker];
    var text_offset: usize = undefined;
    var text_len: usize = undefined;

    if (len_byte == 0x81) {
        // 2-byte little-endian length
        if (after_marker + 3 > data.len) return null;
        text_len = std.mem.readInt(u16, data[after_marker + 1 ..][0..2], .little);
        text_offset = after_marker + 3;
    } else if (len_byte == 0x82) {
        // 4-byte little-endian length
        if (after_marker + 5 > data.len) return null;
        text_len = std.mem.readInt(u32, data[after_marker + 1 ..][0..4], .little);
        text_offset = after_marker + 5;
    } else {
        // Single-byte length (most common for short messages)
        text_len = @intCast(len_byte);
        text_offset = after_marker + 1;
    }

    if (text_len == 0) return null;
    if (text_offset + text_len > data.len) return null;

    const text = data[text_offset..][0..text_len];

    // Sanity check: result should be valid UTF-8.
    if (!std.unicode.utf8ValidateSlice(text)) return null;

    return text;
}

// ── Tests ───────────────────────────────────────────────────────────

test "decode single-byte length" {
    // Marker + length 5 + "hello"
    const blob = [_]u8{ 0x00, 0x84, 0x01, 0x2b, 0x05 } ++ "hello".*;
    const result = decodeAttributedBody(&blob);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello", result.?);
}

test "decode 2-byte LE length" {
    // Marker + 0x81 + LE16(5) + "world"
    const blob = [_]u8{ 0x84, 0x01, 0x2b, 0x81, 0x05, 0x00 } ++ "world".*;
    const result = decodeAttributedBody(&blob);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("world", result.?);
}

test "decode 4-byte LE length" {
    // Marker + 0x82 + LE32(3) + "abc"
    const blob = [_]u8{ 0x84, 0x01, 0x2b, 0x82, 0x03, 0x00, 0x00, 0x00 } ++ "abc".*;
    const result = decodeAttributedBody(&blob);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("abc", result.?);
}

test "decode empty blob returns null" {
    try std.testing.expect(decodeAttributedBody(&[_]u8{}) == null);
}

test "decode null input returns null" {
    try std.testing.expect(decodeAttributedBody(null) == null);
}

test "decode malformed blob (no marker) returns null" {
    const blob = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expect(decodeAttributedBody(&blob) == null);
}

test "decode truncated after marker returns null" {
    const blob = [_]u8{ 0x84, 0x01, 0x2b };
    try std.testing.expect(decodeAttributedBody(&blob) == null);
}

test "decode length exceeds blob returns null" {
    // Claims 255 bytes but only 3 available
    const blob = [_]u8{ 0x84, 0x01, 0x2b, 0xFF } ++ "abc".*;
    try std.testing.expect(decodeAttributedBody(&blob) == null);
}

test "decode zero length returns null" {
    const blob = [_]u8{ 0x84, 0x01, 0x2b, 0x00 };
    try std.testing.expect(decodeAttributedBody(&blob) == null);
}
