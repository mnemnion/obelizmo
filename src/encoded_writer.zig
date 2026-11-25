//! EncodedWriter
//!
//! Most formats of interest targeted by `obelizmo` also call for some changes to
//! the text itself.  HTML, for instance, requires transformation of `<` to `&lt;`,
//! and so on, terminal printing may be spoofed if control sequences are printed directly,
//! and so on.
//!
//! EncodedWriter is a specialized writer which allows for this.  In addition to a subset
//! of Writer inteface functions used by Obelizmo writers (write, writeAll, and print), it
//! needs a writeEncode function.  This is called for any spans of bare text between marks.
//!
//! Included are EncodedWriters for Xterm-style terminal printing, and for HTML escaping.
//! The latter does not attempt to ampersand-encode non-mandatory characters, but will allow
//! properly formed ampersand entities through without re-encoding them.

const std = @import("std");
const ErrorOf = @import("colors").ErrorOf;

/// Returns a type which wraps another Writer, and takes a pointer to a
/// function for performing encoded writes.  An instance of this type
/// has two methods, `writeEncode`, which calls the provided function
/// with the Writer, and `write`, which uses the underlying write method
/// of the wrapped type.
///
/// Because this type doesn't modify the write function itself, it doesn't
/// expose the standard Writer interface.
pub fn EncodedWriter(
    WriterType: type,
    writeEncodeFn: *const fn (writer: WriterType, bytes: []const u8) ErrorOf(WriterType)!usize,
) type {
    return struct {
        context: WriterType,
        const EncodeWrite = @This();
        pub const Error = ErrorOf(WriterType);

        pub fn init(context: WriterType) EncodeWrite {
            return EncodeWrite{ .context = context };
        }

        /// Encode the entire slice or return an error; report encoded output bytes.
        pub fn writeEncode(e_write: EncodeWrite, bytes: []const u8) Error!usize {
            return writeEncodeFn(e_write.context, bytes);
        }

        pub fn write(e_write: EncodeWrite, bytes: []const u8) Error!usize {
            return e_write.context.write(bytes);
        }

        pub fn writeAll(e_write: EncodeWrite, bytes: []const u8) Error!void {
            return e_write.context.writeAll(bytes);
        }

        pub fn print(e_write: EncodeWrite, comptime fmt: []const u8, args: anytype) Error!void {
            return e_write.context.print(fmt, args);
        }
    };
}

/// Return an EncodedWriter which will escape HTML markup characters into
/// their character entity form.
pub fn HtmlEncodedWriter(WriterType: type) type {
    const writeEncodeFn = htmlEscapeEncoder(WriterType);
    return EncodedWriter(WriterType, writeEncodeFn);
}

/// Return an EncodedWriter which does no encoding of the bytes provided.
pub fn DefaultEncodedWriter(WriterType: type) type {
    const defaultEncodeFn = struct {
        fn writeEncode(writer: WriterType, bytes: []const u8) ErrorOf(WriterType)!usize {
            return writeAllCount(writer, bytes);
        }
    }.writeEncode;
    return EncodedWriter(WriterType, defaultEncodeFn);
}

const control_pic = fill: {
    var control_pic_fill: [32]u21 = @splat(0);
    for (0x2400..0x241f, 0..) |c, i| {
        if (i == 8) {
            // We call 0x08 "delete" now, historically "backspace", now 0x7f
            control_pic_fill[i] = '␡';
        } else {
            control_pic_fill[i] = @intCast(c);
        }
    }
    break :fill control_pic_fill;
};

/// Return an EncodedWriter which escapes non-printing C0 and all C1 codes.
pub fn XtermEncodedWriter(WriterType: type) type {
    const xTermEncodeFn = struct {
        fn writeEncode(writer: WriterType, bytes: []const u8) ErrorOf(WriterType)!usize {
            var cursor: usize = 0;
            var idx: usize = 0;
            var count: usize = 0;
            while (idx < bytes.len) : (idx += 1) {
                const b = bytes[idx];
                switch (b) {
                    0...0x08, // '\t', '\n'
                    0x0b...0x0c, // '\r'
                    0x0e...0x1f,
                    => {
                        count += try writeAllCount(writer, bytes[cursor..idx]);
                        try writer.print("{u}", .{control_pic[b]});
                        count += 3;
                        cursor = idx + 1;
                    },
                    0x7f => {
                        count += try writeAllCount(writer, bytes[cursor..idx]);
                        try writer.writeAll("␈");
                        count += 3;
                        cursor = idx + 1;
                    },
                    0xc2 => {
                        if (idx + 1 < bytes.len) {
                            const b1 = bytes[idx + 1];
                            if (0x80 <= b1 and b1 <= 0x9f) {
                                count += try writeAllCount(writer, bytes[cursor..idx]);
                                idx += 1;
                                // Convenient property: Codepoint value of C1s is just
                                // the second byte. Written in 'vi format' as e.g <80>
                                try writer.print("<{x:0>2}>", .{b1});
                                count += 4;
                                cursor = idx + 1;
                            }
                        }
                    },
                    else => {},
                }
            }
            count += try writeAllCount(writer, bytes[cursor..idx]);
            return count;
        }
    }.writeEncode;
    return EncodedWriter(WriterType, xTermEncodeFn);
}

/// Return a `writeEncode` function compatible with an `EncodedWriter` specialized
/// for the provided WriterType, which escapes HTML encoded entities.
pub fn htmlEscapeEncoder(
    WriterType: type,
) fn (WriterType, []const u8) ErrorOf(WriterType)!usize {
    return struct {
        // TODO more efficient to write out when we hit an entity,
        // rather than calling writeByte so often.
        fn writeEncodeFn(writer: WriterType, bytes: []const u8) ErrorOf(WriterType)!usize {
            var count: usize = 0;
            for (bytes, 0..) |byte, i| {
                count += count: {
                    switch (byte) {
                        '<' => break :count try writeAllCount(writer, "&lt;"),
                        '>' => break :count try writeAllCount(writer, "&gt;"),
                        '&' => {
                            if (isEntity(bytes[i..])) {
                                break :count try writeAllCount(writer, "&");
                            } else {
                                break :count try writeAllCount(writer, "&amp;");
                            }
                        },
                        else => |b| {
                            try writer.writeByte(b);
                            break :count 1;
                        },
                    }
                };
            }
            return count;
        }
    }.writeEncodeFn;
}

fn writeAllCount(writer: anytype, bytes: []const u8) ErrorOf(@TypeOf(writer))!usize {
    try writer.writeAll(bytes);
    return bytes.len;
}

fn isEntity(slice: []const u8) bool {
    // Minimum entity length is 3, like "&a;"
    if (slice.len < 3) return false;
    std.debug.assert(slice[0] == '&');

    var i: usize = 1;

    if (slice[i] == '#') {
        // Could be a numeric.
        i += 1;
        if (i >= slice.len) return false;
        // Hexadecimal?
        if (slice[i] == 'x' or slice[i] == 'X') {
            i += 1;
            while (i < slice.len and (std.ascii.isHex(slice[i]))) : (i += 1) {}
        } else {
            // Could be decimal.
            while (i < slice.len and std.ascii.isDigit(slice[i])) : (i += 1) {}
        }
    } else {
        // Could be a named entity.
        while (i < slice.len and std.ascii.isAlphabetic(slice[i])) : (i += 1) {}
    }

    // Entity must end with a semicolon
    return i < slice.len and slice[i] == ';';
}

// Example usage
test "isEntity" {
    const test_cases = [_][]const u8{
        "&amp;", // True: Named entity
        "&#123;", // True: Decimal entity
        "&#x1F4A9;", // True: Hexadecimal entity
        "&wrong", // False: Missing semicolon
        "&wrong ;", // False: Non-alphabetic before semicolon
        "&x123;", // False: Invalid numeric or alphabetic entity
        "&;", // False: Too short
    };

    const expected_results = [_]bool{
        true, true, true, false, false, false, false,
    };

    for (test_cases, 0..) |test_case, i| {
        const result = isEntity(test_case);
        try std.testing.expect(result == expected_results[i]);
    }
}

test "htmlEscapeEncoder" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const encodeFn = htmlEscapeEncoder(@TypeOf(&aw.writer));
    const encodable = "A & B < C is&nbsp;> D";
    const out_amount = try encodeFn(&aw.writer, encodable);
    const out_str = try allocator.dupe(u8, aw.writer.buffered());
    defer allocator.free(out_str);
    try std.testing.expectEqual(31, out_amount);
    try std.testing.expectEqualStrings("A &amp; B &lt; C is&nbsp;&gt; D", out_str);
}

test "HtmlEncodedWriter" {
    const allocator = std.testing.allocator;
    var array_writer: std.Io.Writer.Allocating = .init(allocator);
    defer array_writer.deinit();
    const EncodedWriteType = HtmlEncodedWriter(@TypeOf(&array_writer.writer));
    const encodable = "A & B < C is&nbsp;> D";
    var encoded_writer = EncodedWriteType.init(&array_writer.writer);
    _ = try encoded_writer.writeEncode(encodable);
    const out_encoded = try allocator.dupe(u8, array_writer.writer.buffered());
    defer allocator.free(out_encoded);
    try std.testing.expectEqualStrings("A &amp; B &lt; C is&nbsp;&gt; D", out_encoded);
    array_writer.writer.end = 0;
    _ = try encoded_writer.write(encodable);
    const out_literal = try allocator.dupe(u8, array_writer.writer.buffered());
    defer allocator.free(out_literal);
    try std.testing.expectEqualStrings(encodable, out_literal);
}

test "encoded writes retain every byte across short writes and buffer flushes" {
    inline for (.{ DefaultEncodedWriter, XtermEncodedWriter, HtmlEncodedWriter }) |Encoder| {
        const source = "prefix<&\x1b\x7f\xc2\x80>suffix\n";
        const expected = if (Encoder == DefaultEncodedWriter)
            source
        else if (Encoder == XtermEncodedWriter)
            "prefix<&␛␈<80>>suffix\n"
        else
            "prefix&lt;&amp;\x1b\x7f\xc2\x80&gt;suffix\n";
        for ([_]usize{ 0, 1, 8 }) |capacity| {
            for ([_]usize{ 1, 3 }) |chunk| {
                var buffer: [8]u8 = undefined;
                var sink: ShortWriter = .{ .chunk = chunk };
                sink.writer.buffer = buffer[0..capacity];
                try sink.writer.writeAll("already buffered: ");
                const encoded = Encoder(*std.Io.Writer).init(&sink.writer);
                const count = try encoded.writeEncode(source);
                try sink.writer.flush();
                try std.testing.expectEqualStrings("already buffered: " ++ expected, sink.bytes[0..sink.len]);
                try std.testing.expectEqual(expected.len, count);
            }
        }
    }
}

test "encoded writes propagate failure after a partial write" {
    inline for (.{ DefaultEncodedWriter, XtermEncodedWriter, HtmlEncodedWriter }) |Encoder| {
        var sink: ShortWriter = .{ .limit = 5 };
        const encoded = Encoder(*std.Io.Writer).init(&sink.writer);
        try std.testing.expectError(error.WriteFailed, encoded.writeEncode("prefix<tail"));
        try std.testing.expectEqualStrings("prefi", sink.bytes[0..sink.len]);
    }
}

const ShortWriter = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    bytes: [256]u8 = undefined,
    len: usize = 0,
    chunk: usize = 3,
    limit: usize = 256,
    pause: bool = true,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const sink: *ShortWriter = @alignCast(@fieldParentPtr("writer", writer));
        sink.pause = !sink.pause;
        if (!sink.pause) return 0;
        if (writer.end != 0) {
            const count = try sink.append(writer.buffered());
            return writer.consume(count);
        }
        for (data, 0..) |part, i| {
            if (i == data.len - 1 and splat == 0) break;
            if (part.len != 0) return sink.append(part);
        }
        return 0;
    }

    fn append(sink: *ShortWriter, bytes: []const u8) std.Io.Writer.Error!usize {
        if (sink.len == sink.limit) return error.WriteFailed;
        const count = @min(bytes.len, sink.chunk, sink.limit - sink.len);
        @memcpy(sink.bytes[sink.len..][0..count], bytes[0..count]);
        sink.len += count;
        return count;
    }
};
