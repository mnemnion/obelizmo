const std = @import("std");

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
    writeEncodeFn: *const fn (writer: *WriterType, bytes: []const u8) WriterType.Error!usize,
) type {
    return struct {
        context: *WriterType,
        const EncodeWrite = @This();
        pub const Error = WriterType.Error;

        pub fn init(context: *WriterType) EncodeWrite {
            return EncodeWrite{ .context = context };
        }

        pub fn writeEncode(e_write: *EncodeWrite, bytes: []const u8) Error!usize {
            return try writeEncodeFn(e_write.context, bytes);
        }

        pub fn write(e_write: *EncodeWrite, bytes: []const u8) Error!usize {
            return try e_write.context.write(bytes);
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
        fn writeEncode(writer: *const WriterType, bytes: []const u8) WriterType.Error!usize {
            return try writer.write(bytes);
        }
    }.writeEncode;
    return EncodedWriter(WriterType, defaultEncodeFn);
}

/// Return a `writeEncode` function compatible with an `EncodedWriter` specialized
/// for the provided WriterType, which escapes HTML encoded entities.
pub fn htmlEscapeEncoder(
    WriterType: type,
) fn (*WriterType, []const u8) WriterType.Error!usize {
    return struct {
        // TODO more efficient to write out when we hit an entity,
        // wrather than calling writeByte so often.
        fn writeEncodeFn(writer: *WriterType, bytes: []const u8) WriterType.Error!usize {
            var count: usize = 0;
            for (bytes, 0..) |byte, i| {
                count += count: {
                    switch (byte) {
                        '<' => break :count try writer.write("&lt;"),
                        '>' => break :count try writer.write("&gt;"),
                        '&' => {
                            if (isEntity(bytes[i..])) {
                                break :count try writer.write("&");
                            } else {
                                break :count try writer.write("&amp;");
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
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var writer = out_array.writer();
    const encodeFn = htmlEscapeEncoder(@TypeOf(writer));
    const encodable = "A & B < C is&nbsp;> D";
    const out_amount = try encodeFn(&writer, encodable);
    const out_str = try out_array.toOwnedSlice();
    defer allocator.free(out_str);
    try std.testing.expectEqual(31, out_amount);
    try std.testing.expectEqualStrings("A &amp; B &lt; C is&nbsp;&gt; D", out_str);
}

test "HtmlEncodedWriter" {
    const allocator = std.testing.allocator;
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var array_writer = out_array.writer();
    const EncodedWriteType = HtmlEncodedWriter(@TypeOf(array_writer));
    const encodable = "A & B < C is&nbsp;> D";
    var encoded_writer = EncodedWriteType.init(&array_writer);
    _ = try encoded_writer.writeEncode(encodable);
    const out_encoded = try out_array.toOwnedSlice();
    defer allocator.free(out_encoded);
    try std.testing.expectEqualStrings("A &amp; B &lt; C is&nbsp;&gt; D", out_encoded);
    _ = try encoded_writer.write(encodable);
    const out_literal = try out_array.toOwnedSlice();
    defer allocator.free(out_literal);
    try std.testing.expectEqualStrings(encodable, out_literal);
}
