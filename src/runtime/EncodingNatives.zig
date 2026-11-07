//! Section 15.12's text encodings as natives (`Native.zig`): Base64, hex, and
//! the SHA-256 digests.

const std = @import("std");
const Heap = @import("Heap.zig");
const Value = @import("Value.zig");
const Native = @import("Native.zig");
const BytesMethods = @import("BytesMethods.zig");
const strings = @import("strings.zig");

const Context = Native.Context;
const Error = Native.Error;

/// Section 15.12's `Base64.encode`: padded in the standard alphabet, unpadded
/// in the URL-safe one.
pub fn base64Encode(ctx: *Context, source: []const u8, url_safe: bool) Error!Value {
    const codec = if (url_safe) std.base64.url_safe_no_pad.Encoder else std.base64.standard.Encoder;
    const out = try ctx.gpa.alloc(u8, codec.calcSize(source.len));
    _ = codec.encode(out, source);
    return .{ .data = .{ .string = try ctx.heap.createText(out) } };
}

/// Section 15.12's `Digest.sha256`, or `Digest.hmac_sha256` with a `key`.
pub fn digest(ctx: *Context, bytes: []const u8, key: ?[]const u8) Error!Value {
    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (key) |secret| {
        std.crypto.auth.hmac.sha2.HmacSha256.create(&out, bytes, secret);
    } else {
        std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    }
    return ctx.heap.copyBytes(&out);
}

pub fn base64Decode(ctx: *Context, text: []const u8, url_safe: bool, maybe: bool) Error!Value {
    // Walk characters, not bytes, so an index matches string indexing and a
    // non-ASCII character is quoted whole rather than as a broken byte.
    const characters = try strings.characters(ctx.gpa, text);
    defer ctx.gpa.free(characters);
    // The Base64 characters kept, each with its index in the original text.
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(ctx.gpa);
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(ctx.gpa);
    const alphabet = if (url_safe) std.base64.url_safe_alphabet_chars else std.base64.standard_alphabet_chars;
    var first_padding: ?usize = null;
    for (characters, 0..) |character, index| {
        // Wrapped Base64 (email, PEM files, copied output) breaks lines; a
        // Windows line ending is one character, "\r\n".
        if (isBase64Space(character)) continue;
        if (character.len == 1 and character[0] == '=') {
            first_padding = first_padding orelse index;
            try clean.append(ctx.gpa, '=');
            try positions.append(ctx.gpa, index);
            continue;
        }
        if (first_padding) |padding_index| {
            if (maybe) return Value.nothing;
            return BytesMethods.raiseEncodingMessage(ctx, try std.fmt.allocPrint(ctx.arena, "Base64 text has `=` at index {d}, before its end", .{padding_index}));
        }
        const known = character.len == 1 and base64Index(alphabet, character[0]) != null;
        if (!known) {
            if (maybe) return Value.nothing;
            const other_alphabet = character.len == 1 and if (url_safe)
                character[0] == '+' or character[0] == '/'
            else
                character[0] == '-' or character[0] == '_';
            if (other_alphabet) {
                const mode = if (url_safe) "standard" else "URL-safe";
                const help = if (url_safe) "Decode it without `url_safe: true`." else "Decode it with `url_safe: true`.";
                const message = try std.fmt.allocPrint(ctx.arena, "Base64 text has `{s}` at index {d}, which belongs to {s} Base64", .{ character, index, mode });
                return ctx.raiseTyped("EncodingError", message, help);
            }
            return BytesMethods.raiseEncodingMessage(ctx, try std.fmt.allocPrint(ctx.arena, "Base64 text has `{s}` at index {d}, which is not a Base64 character", .{ character, index }));
        }
        try clean.append(ctx.gpa, character[0]);
        try positions.append(ctx.gpa, index);
    }
    var padding: usize = 0;
    while (padding < clean.items.len and clean.items[clean.items.len - 1 - padding] == '=') : (padding += 1) {}
    const encoded = clean.items[0 .. clean.items.len - padding];
    if (encoded.len % 4 == 1) {
        if (maybe) return Value.nothing;
        return BytesMethods.raiseEncodingMessage(ctx, "Base64 text ends partway through a group: it has 1 character too many, or is missing some");
    }
    // Four characters make a group; a last group of two or three is padded
    // with two or one `=`, and a complete group with none.
    const needed: usize = (4 - encoded.len % 4) % 4;
    if (padding > 0 and padding != needed) {
        if (maybe) return Value.nothing;
        const message = if (needed == 0)
            try std.fmt.allocPrint(ctx.arena, "Base64 text ends with {d} `=`, but its last group is already complete and needs none", .{padding})
        else
            try std.fmt.allocPrint(ctx.arena, "Base64 text ends with {d} `=`, but its last group needs {d}", .{ padding, needed });
        return BytesMethods.raiseEncodingMessage(ctx, message);
    }
    if (encoded.len % 4 != 0) {
        const last = encoded[encoded.len - 1];
        const value = base64Index(alphabet, last).?;
        const mask: u8 = if (encoded.len % 4 == 2) 0x0f else 0x03;
        if ((value & mask) != 0) {
            if (maybe) return Value.nothing;
            const canonical = alphabet[value & ~mask];
            return BytesMethods.raiseEncodingMessage(ctx, try std.fmt.allocPrint(ctx.arena, "Base64 text's last character, `{c}` at index {d}, is not a possible final character; write `{c}` instead", .{ last, positions.items[encoded.len - 1], canonical }));
        }
    }
    const decoder = if (url_safe) std.base64.url_safe_no_pad.Decoder else std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch unreachable;
    const out = try ctx.gpa.alloc(u8, size);
    decoder.decode(out, encoded) catch unreachable;
    return .{ .data = .{ .bytes = try ctx.heap.createText(out) } };
}

pub fn isBase64Space(character: []const u8) bool {
    for (character) |byte| switch (byte) {
        ' ', '\t', '\r', '\n' => {},
        else => return false,
    };
    return character.len > 0;
}

pub fn base64Index(alphabet: [64]u8, character: u8) ?u8 {
    for (alphabet, 0..) |candidate, index| if (candidate == character) return @intCast(index);
    return null;
}

pub fn bytesFromHex(ctx: *Context, text: []const u8, maybe: bool) Error!Value {
    const characters = try strings.characters(ctx.gpa, text);
    defer ctx.gpa.free(characters);
    if (characters.len % 2 != 0) {
        if (maybe) return Value.nothing;
        return BytesMethods.raiseEncodingMessage(ctx, try std.fmt.allocPrint(ctx.arena, "hex text has {d} digits, but every byte takes two", .{characters.len}));
    }

    const bytes = try ctx.gpa.alloc(u8, characters.len / 2);
    for (characters, 0..) |character, index| {
        const digit = hexValue(character) orelse {
            ctx.gpa.free(bytes);
            if (maybe) return Value.nothing;
            return BytesMethods.raiseEncodingMessage(ctx, try std.fmt.allocPrint(ctx.arena, "hex text has `{s}` at index {d}, which is not a hex digit", .{ character, index }));
        };
        if (index % 2 == 0) {
            bytes[index / 2] = digit << 4;
        } else {
            bytes[index / 2] |= digit;
        }
    }
    return .{ .data = .{ .bytes = try ctx.heap.createText(bytes) } };
}

pub fn hexValue(character: []const u8) ?u8 {
    if (character.len != 1) return null;
    return switch (character[0]) {
        '0'...'9' => character[0] - '0',
        'a'...'f' => character[0] - 'a' + 10,
        'A'...'F' => character[0] - 'A' + 10,
        else => null,
    };
}
