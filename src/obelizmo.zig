const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue;
const Order = std.math.Order;

const encoded_writer = @import("encoded_writer.zig");

pub const EncodedWriter = encoded_writer.EncodedWriter;
pub const HtmlEncodedWriter = encoded_writer.HtmlEncodedWriter;
pub const DefaultEncodedWriter = encoded_writer.DefaultEncodedWriter;

pub fn MarkedString(Kind: type) type {
    switch (@typeInfo(Kind)) {
        .Enum => {},
        else => @compileError("MarkedString must be given an enum"),
    }

    return struct {
        string: []const u8,
        queue: MarkQueue,

        const SMark = @This();

        /// A single `Mark` on a `MarkedString`.
        pub const Mark = struct {
            kind: Kind,
            offset: u32,
            len: u32,

            /// Obtain the final boundary of the `Mark`.
            pub fn final(mark: @This()) u32 {
                return mark.offset + mark.len;
            }
        };

        /// The EnumArray type expected by MarkedString printing functions.
        /// Initialized with a value of `[2][]const u8`, representing a pair of
        /// bookends for printing the marked string.  For information in setting
        /// up and using this type, see `std.enums.EnumArray`.
        pub const MarkupArray = std.enums.EnumArray(Kind, [2][]const u8);

        /// Queue for applying `Mark`s, type of the .queue field of a
        /// `MarkedString`.
        pub const MarkQueue = PriorityQueue(Mark, void, compare);

        /// Queue for writing `Marks`.
        pub const OutQueue = PriorityQueue(Mark, void, compareEnds);

        //| Allocate and Free

        /// Initialize a MarkedString.  The string is not considered to be
        /// owned by the MarkedString, as such, the caller is responsible
        /// for its memory.  Call `marker.deinit()` to free the memory of
        /// the `MarkedString`.
        pub fn init(allocator: Allocator, string: []const u8) SMark {
            return SMark{
                .string = string,
                .queue = MarkQueue.init(allocator, {}),
            };
        }

        /// Initialize a MarkedString with a given capacity.  The string
        /// itself is not owned by the MarkedString, and the caller is
        /// responsible for managing it.  Call `marker.deinit()` to free
        /// the MarkedString.
        pub fn initCapacity(
            allocator: Allocator,
            string: []const u8,
            cap: usize,
        ) error{OutOfMemory}!SMark {
            var m_queue = MarkQueue.init(allocator, {});
            try m_queue.ensureTotalCapacity(cap);
            return SMark{
                .string = string,
                .queue = m_queue,
            };
        }

        /// Free memory allocated by the MarkedString.  The string is
        /// not considered to be owned by the marker, and will not be
        /// deinitialized: this allows for, among other things, marks
        /// to be applied to an .rodata constant string.
        pub fn deinit(marker: *SMark) void {
            marker.queue.deinit();
        }

        //| Marking

        /// Mark the slice `string[start..end]` with the provided `mark`.
        pub fn markSlice(
            marker: *SMark,
            mark: Kind,
            start: usize,
            end: usize,
        ) error{ OutOfMemory, InvalidRegion }!void {
            if (start > end or end > marker.string.len) return error.InvalidRegion;
            const the_mark = Mark{
                .kind = mark,
                .offset = @intCast(start),
                .len = @intCast(end - start),
            };
            try marker.queue.add(the_mark);
        }

        /// Mark the slice `string[start..end]` with the provided `mark`.
        /// Asserts that the bounds provided form a valid slice of the
        /// string.
        pub fn markSliceUnchecked(
            marker: *SMark,
            mark: Kind,
            start: usize,
            end: usize,
        ) error{OutOfMemory}!void {
            assert(start < end and end <= marker.string.len);
            const the_mark = Mark{
                .kind = mark,
                .offset = @intCast(start),
                .len = @intCast(end - start),
            };
            try marker.queue.add(the_mark);
        }

        /// Mark `len` bytes of the string starting from `offset`.
        pub fn markFrom(
            marker: *SMark,
            mark: Kind,
            offset: usize,
            len: usize,
        ) error{ OutOfMemory, InvalidRegion }!void {
            if (offset + len > marker.string.len or offset > marker.string.len)
                return error.InvalidRegion;
            const the_mark = Mark{
                .kind = mark,
                .offset = @intCast(offset),
                .len = @intCast(len),
            };
            try marker.queue.add(the_mark);
        }

        /// Mark `len` bytes of the string starting from `offset`.
        /// Asserts that the provided values are within the bounds
        /// of the string.
        pub fn markFromUnchecked(
            marker: *SMark,
            mark: Kind,
            offset: usize,
            len: usize,
        ) error{OutOfMemory}!void {
            assert(offset + len <= marker.string.len);
            const the_mark = Mark{
                .kind = mark,
                .offset = @intCast(offset),
                .len = @intCast(len),
            };
            try marker.queue.add(the_mark);
        }

        /// Find `needle` in string and mark with `mark`.  Returns the
        /// index if the needle was found and marked, otherwise `null`.
        pub fn findAndMark(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
        ) error{OutOfMemory}!?usize {
            const idx = std.mem.indexOf(u8, marker.string, needle);
            if (idx) |i| {
                try marker.markFromUnchecked(mark, i, needle.len);
            }
            return idx;
        }

        /// Find `needle` in string after `pos`, and mark with `mark`.
        /// Returns the index if the needle was found and marked,
        /// otherwise `null`.
        pub fn findAndMarkPos(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
            pos: usize,
        ) error{OutOfMemory}!?usize {
            const idx = std.mem.indexOfPos(u8, marker.string, pos, needle);
            if (idx) |i| {
                try marker.markFromUnchecked(mark, i, needle.len);
            }
            return idx;
        }

        /// Find last occurence of `needle` in string, and mark with
        /// `mark`.  Returns the index if the needle was found and
        ///  marked, `null` otherwise.
        pub fn findAndMarkLast(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
        ) error{OutOfMemory}!bool {
            const idx = std.mem.lastIndexOf(u8, marker.string, needle);
            if (idx) |i| {
                try marker.markFromUnchecked(mark, i, needle.len);
            }
            return idx;
        }

        /// Match the string with an `mvzr` Regex, and mark the matched
        /// region.  Returns the index of the match, or `null` if there
        /// is none.
        pub fn matchAndMark(
            marker: *SMark,
            mark: Kind,
            regex: anytype,
        ) error{OutOfMemory}!?usize {
            const maybe_match = regex.match(marker.string);
            if (maybe_match) |match| {
                try marker.markSliceUnchecked(mark, match.start, match.end);
                return match.start;
            } else {
                return null;
            }
        }

        /// Match the string with an `mvzr` Regex, starting from `pos`,
        /// and mark the matched region.  Returns the index of the match,
        /// or `null` if there is none.
        pub fn matchAndMarkPos(
            marker: *SMark,
            mark: Kind,
            pos: usize,
            regex: anytype,
        ) error{OutOfMemory}!?usize {
            const maybe_match = regex.matchPos(pos, marker.string);
            if (maybe_match) |match| {
                try marker.markSliceUnchecked(mark, match.start, match.end);
                return match.start;
            } else {
                return null;
            }
        }

        /// Match the string with an `mvzr` Regex, and mark all matched
        /// regions.  Returns `true` if there were any matches, `false`
        /// otherwise.
        pub fn matchAndMarkAll(
            marker: *SMark,
            mark: Kind,
            regex: anytype,
        ) error{OutOfMemory}!bool {
            var matcher = regex.iterator(marker.string);
            var a_match = false;
            while (matcher.next()) |match| {
                a_match = true;
                try marker.markSliceUnchecked(mark, match.start, match.end);
            }
            return a_match;
        }

        //| Writing

        fn cloneQueue(queue: MarkQueue) error{OutOfMemory}!MarkQueue {
            const nu_q_slice = try queue.allocator.alloc(Mark, queue.items.len);
            @memcpy(nu_q_slice, queue.items);
            return MarkQueue{
                .allocator = queue.allocator,
                .items = nu_q_slice,
                .cap = nu_q_slice.len,
                .context = {},
            };
        }

        const LEFT: usize = 0;
        const RIGHT: usize = 1;

        /// Write the MarkedString to the given writer as a stream.
        /// re-starting any outer style once an inner style is closed,
        /// as is helpful, specifically, when writing to the terminal.
        pub fn writeAsStream(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupArray,
        ) @TypeOf(writer.*).Error!usize {
            // See if there's a writeEncode function.
            const WriteT = @TypeOf(writer.*);
            const writeBody = if (@hasDecl(WriteT, "writeEncode"))
                WriteT.writeEncode
            else
                WriteT.write;
            // We use a second queue with a different comparison function, such
            // that the front of the queue is always the next-outermost Mark.
            const allocator = marker.queue.allocator;
            const string = marker.string;
            var in_q = try cloneQueue(marker.queue);
            defer in_q.deinit();
            var out_q = OutQueue.init(allocator, {});
            defer out_q.deinit();
            // Some rounds of the while loop will skip a mark, so we pop the queue
            // manually:
            var this_mark = in_q.removeOrNull();
            var cursor: usize = 0;
            var count: usize = 0;
            marking: while (this_mark) |mark| {
                const maybe_next = out_q.peek();
                var from_this_mark = true; // determines where we get our offset
                const next_idx = idx: {
                    if (maybe_next) |next_mark| {
                        const next_mark_end = next_mark.final();
                        if (next_mark_end < mark.offset) {
                            from_this_mark = false;
                            break :idx next_mark_end;
                        } else {
                            break :idx mark.offset;
                        }
                    } else {
                        break :idx mark.offset;
                    }
                };
                // Write up to our next obelus
                if (cursor < next_idx) {
                    count += try writeBody(writer.*, string[cursor..next_idx]);
                }
                cursor = next_idx;
                if (from_this_mark) {
                    // Write our bookend.
                    const left = markups.get(mark.kind)[LEFT];
                    count += try writer.write(left);
                    // Enplace on the out queue.
                    try out_q.add(mark);
                    // Replace mark.
                    this_mark = in_q.removeOrNull();
                    continue :marking;
                } else {
                    // This mark isn't up yet, write the end off the queue.
                    const end_mark = out_q.remove();
                    const right = markups.get(end_mark.kind)[RIGHT];
                    count += try writer.write(right);
                    // Now stream the left mark from the next on-queue, if any.
                    const maybe_left_mark = out_q.peek();
                    if (maybe_left_mark) |left_mark| {
                        if (left_mark.final() == cursor) {
                            // Skip the opening mark
                            _ = out_q.remove();
                            // Write the closing mark;
                            const next_right = markups.get(left_mark.kind)[RIGHT];
                            count += try writer.write(next_right);
                        } else {
                            const left = markups.get(left_mark.kind)[LEFT];
                            count += try writer.write(left);
                        }
                    }
                    continue :marking;
                }
            } // end :marking
            // There may still be marks on the out queue to drain
            while (out_q.removeOrNull()) |out_mark| {
                const slice_end = out_mark.final();
                count += try writeBody(writer.*, string[cursor..slice_end]);
                cursor = slice_end;
                const right = markups.get(out_mark.kind)[RIGHT];
                count += try writer.write(right);
                const maybe_left_mark = out_q.peek();
                if (maybe_left_mark) |left_mark| {
                    const left = markups.get(left_mark.kind)[LEFT];
                    count += try writer.write(left);
                }
            }
            // Write the rest of the string, if any
            count += try writeBody(writer.*, string[cursor..]);

            return count;
        }

        /// Write the `MarkedString` as a tree.  This is more compatible
        /// with XML/HTML style markup, where each marked region is a
        /// span or such.  Every mark is begun and ended once, with no
        /// logic to restart an outer span once an inner span is closed,
        /// as is necessary to get good results printing to a terminal.
        /// For that purpose, use `writeAsStream`.  Note that this must
        /// be called with an `EncodedWriter`, or some type offering
        /// compatible functions.
        pub fn writeAsTree(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupArray,
        ) @TypeOf(writer.*).Error!usize {
            // See if there's a writeEncode function.
            const WriteT = @TypeOf(writer.*);
            const writeBody = if (@hasDecl(WriteT, "writeEncode"))
                WriteT.writeEncode
            else
                WriteT.write;
            // We use a second queue with a different comparison function, such
            // that the front of the queue is always the next-outermost Mark.
            const allocator = marker.queue.allocator;
            const string = marker.string;
            var in_q = try cloneQueue(marker.queue);
            defer in_q.deinit();
            var out_q = OutQueue.init(allocator, {});
            defer out_q.deinit();
            // Some rounds of the while loop will skip a mark, so we pop the queue
            // manually:
            var this_mark = in_q.removeOrNull();
            var cursor: usize = 0;
            var count: usize = 0;
            marking: while (this_mark) |mark| {
                const maybe_next = out_q.peek();
                var from_this_mark = true; // Determines where we get our index
                const next_idx = idx: {
                    if (maybe_next) |next_mark| {
                        const next_mark_end = next_mark.final();
                        if (next_mark_end < mark.offset) {
                            from_this_mark = false;
                            break :idx next_mark_end;
                        } else {
                            break :idx mark.offset;
                        }
                    } else {
                        break :idx mark.offset;
                    }
                };
                // Write up to our next obelus
                if (cursor < next_idx) {
                    count += try writeBody(writer.*, string[cursor..next_idx]);
                }
                cursor = next_idx;
                if (from_this_mark) {
                    // Write our bookend.
                    const left = markups.get(mark.kind)[LEFT];
                    count += try writer.write(left);
                    // Enplace on the out queue.
                    try out_q.add(mark);
                    // Replace mark.
                    this_mark = in_q.removeOrNull();
                    continue :marking;
                } else {
                    // This mark isn't up yet, write the end off the queue.
                    const end_mark = out_q.remove();
                    const right = markups.get(end_mark.kind)[RIGHT];
                    count += try writer.write(right);
                    // Now stream the left mark from the next on-queue, if any.
                    continue :marking;
                }
            } // end :marking
            // There may still be marks on the out queue to drain
            while (out_q.removeOrNull()) |out_mark| {
                const slice_end = out_mark.final();
                count += try writeBody(writer.*, string[cursor..slice_end]);
                cursor = slice_end;
                const right = markups.get(out_mark.kind)[RIGHT];
                count += try writer.write(right);
            }
            // Write the rest of the string, if any
            count += try writeBody(writer.*, string[cursor..]);

            return count;
        }

        /// Our sort will yield an in-order top down tree:
        /// All marks which start before another mark come before
        /// all later marks, with all longer marks before shorter
        /// ones.  Ties are broken by enum order, this is somewhat
        /// arbitrary, but at least predictable.
        fn compare(_: void, left: Mark, right: Mark) Order {
            if (left.offset < right.offset) {
                return Order.lt;
            } else if (left.offset > right.offset) {
                return Order.gt;
            } else if (left.len < right.len) {
                return Order.gt;
            } else if (left.len > right.len) {
                return Order.lt;
            } else if (@intFromEnum(left.kind) < @intFromEnum(right.kind)) {
                return Order.lt;
            } else if (@intFromEnum(left.kind) > @intFromEnum(right.kind)) {
                return Order.gt;
            } else {
                return Order.eq;
            }
        }

        /// This compare function is used for the out queue,
        /// so first checks offset + len, and second, len alone.
        /// The tie-breaker by enum is in the opposite order, so
        /// that two different enums of the same offset and len
        /// will be applied in the correct order, such that one
        /// nests within the other.
        fn compareEnds(_: void, left: Mark, right: Mark) Order {
            const l_final = left.final();
            const r_final = right.final();
            if (l_final < r_final) {
                return Order.lt;
            } else if (l_final > r_final) {
                return Order.gt;
            } else if (left.len < right.len) {
                return Order.lt;
            } else if (left.len > right.len) {
                return Order.gt;
            } else if (@intFromEnum(left.kind) < @intFromEnum(right.kind)) {
                return Order.gt;
            } else if (@intFromEnum(left.kind) > @intFromEnum(right.kind)) {
                return Order.lt;
            } else return Order.eq;
        }
    };
}

//| TESTS

const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
const expectEqualStrings = testing.expectEqualStrings;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const OhSnap = @import("ohsnap");

test "MarkedString" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};
    const e_num = enum {
        la,
        dee,
        dah,
    };
    const SM = MarkedString(e_num);
    var markup = SM.init(allocator, "blue green red");
    defer markup.deinit();
    try markup.markSlice(.la, 0, 4);
    try markup.markSlice(.dee, 0, 11);
    try markup.markSlice(.dah, 11, 14);
    try oh.snap(
        @src(),
        \\[]obelizmo.MarkedString(..).Mark
        \\  [0]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .dee
        \\    .offset: u32 = 0
        \\    .len: u32 = 11
        \\  [1]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .la
        \\    .offset: u32 = 0
        \\    .len: u32 = 4
        \\  [2]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .dah
        \\    .offset: u32 = 11
        \\    .len: u32 = 3
        ,
    ).expectEqual(markup.queue.items);
    try oh.snap(
        @src(),
        \\type
        \\  enums.EnumArray(obelizmo.test.MarkedString.e_num,[2][]const u8)
        ,
    ).expectEqual(SM.MarkupArray);
}

const Colors = enum {
    red,
    blue,
    green,
    yellow,
    teal,
    // etc
};

const ColorMarker = MarkedString(Colors);
const ColorArray = ColorMarker.MarkupArray;
const color_markup = ColorArray.init(
    .{
        .red = .{ "<r>", "</r>" },
        .blue = .{ "<b>", "</b>" },
        .green = .{ "<g>", "</g>" },
        .yellow = .{ "<y>", "</y>" },
        .teal = .{ "<t>", "</t>" },
    },
);

test "MarkedString writeAsStream writeAsTree" {
    const oh = OhSnap{};
    const allocator = testing.allocator;
    var color_marker = try ColorMarker.initCapacity(allocator, "red blue green yellow", 4);
    defer color_marker.deinit();
    try expectEqual(0, try color_marker.findAndMark(.red, "red"));
    try expectEqual(15, try color_marker.findAndMark(.yellow, "yellow"));
    try expectEqual(9, try color_marker.findAndMark(.green, "green"));
    try expectEqual(4, try color_marker.findAndMark(.blue, "blue"));
    try color_marker.markSlice(.teal, 4, 14);
    try oh.snap(
        @src(),
        \\[]obelizmo.MarkedString(..).Mark
        \\  [0]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.Colors
        \\      .red
        \\    .offset: u32 = 0
        \\    .len: u32 = 3
        \\  [1]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.Colors
        \\      .teal
        \\    .offset: u32 = 4
        \\    .len: u32 = 10
        \\  [2]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.Colors
        \\      .green
        \\    .offset: u32 = 9
        \\    .len: u32 = 5
        \\  [3]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.Colors
        \\      .yellow
        \\    .offset: u32 = 15
        \\    .len: u32 = 6
        \\  [4]: obelizmo.MarkedString(..).Mark
        \\    .kind: obelizmo.Colors
        \\      .blue
        \\    .offset: u32 = 4
        \\    .len: u32 = 4
        ,
    ).expectEqual(color_marker.queue.items);
    try expectEqual(
        color_marker.queue.items[1].final(),
        color_marker.queue.items[2].final(),
    );
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var stream_writer = out_array.writer();
    _ = try color_marker.writeAsStream(&stream_writer, color_markup);
    const stream_string = try out_array.toOwnedSlice();
    defer allocator.free(stream_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>red</r> <t><b>blue</b><t> <g>green</g></t> <y>yellow</y>"
        ,
    ).expectEqual(stream_string);
    var wrapped_stream = encoded_writer.DefaultEncodedWriter(@TypeOf(stream_writer)).init(&stream_writer);
    _ = try color_marker.writeAsTree(&wrapped_stream, color_markup);
    const tree_string = try out_array.toOwnedSlice();
    defer allocator.free(tree_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>red</r> <t><b>blue</b> <g>green</g></t> <y>yellow</y>"
        ,
    ).expectEqual(tree_string);
}

const Regex = @import("mvzr").Regex;

test "MarkedString regex" {
    const oh = OhSnap{};
    const allocator = testing.allocator;
    var color_marker = try ColorMarker.initCapacity(allocator, "func 10 funky 456", 4);
    defer color_marker.deinit();
    const num_regex = Regex.compile("\\d+").?;
    try expectEqual(5, color_marker.matchAndMark(.blue, num_regex));
    try expectEqual(14, try color_marker.matchAndMarkPos(.blue, 7, num_regex));
    const alpha_regex = Regex.compile("[a-z]+").?;
    try expect(try color_marker.matchAndMarkAll(.red, alpha_regex));
    const u_regex = Regex.compile("u").?;
    try expectEqual(9, try color_marker.matchAndMarkPos(.yellow, 5, u_regex));
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var writer = out_array.writer();
    _ = try color_marker.writeAsStream(&writer, color_markup);
    const stream_string = try out_array.toOwnedSlice();
    defer allocator.free(stream_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>func</r> <b>10</b> <r>f<y>u</y><r>nky</r> <b>456</b>"
        ,
    ).expectEqual(stream_string);
    var wrapped_writer = encoded_writer.DefaultEncodedWriter(@TypeOf(writer)).init(&writer);
    _ = try color_marker.writeAsTree(&wrapped_writer, color_markup);
    const tree_string = try out_array.toOwnedSlice();
    defer allocator.free(tree_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>func</r> <b>10</b> <r>f<y>u</y>nky</r> <b>456</b>"
        ,
    ).expectEqual(tree_string);
}
