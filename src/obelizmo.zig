const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue;
const Order = std.math.Order;

pub fn MarkedString(Kind: type) type {
    switch (@typeInfo(Kind)) {
        .Enum => {},
        else => @compileError("MarkedString must be given an enum"),
    }

    const Mark = struct {
        kind: Kind,
        offset: u32,
        len: u32,

        fn final(mark: @This()) u32 {
            return mark.offset + mark.len;
        }

        fn value(mark: @This()) usize {
            return @intFromEnum(mark.kind);
        }
    };

    return struct {
        string: []const u8,
        queue: MarkQueue,

        const SMark = @This();

        /// Queue for applying Marks.
        const MarkQueue = PriorityQueue(Mark, void, compare);

        /// Queue for writing Marks.
        const SweepQueue = PriorityQueue(Mark, void, compareEnds);

        /// The EnumArray type expected by MarkedString printing functions.
        /// Initialized with a value of `[2][]const u8`, representing a pair of
        /// bookends for printing the marked string.  For information in setting
        /// up and using this type, see `std.enums.EnumArray`.
        pub const MarkupArray = std.enums.EnumArray(Kind, [2][]const u8);

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

        /// Mark the slice `string[start..end]` with the provided `mark`.
        pub fn markSlice(
            marker: *SMark,
            mark: Kind,
            start: usize,
            end: usize,
        ) !void {
            if (start > end) return error.InvalidSliceBoundary;
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
        ) !void {
            const the_mark = Mark{
                .kind = mark,
                .offset = @intCast(offset),
                .len = @intCast(len),
            };
            try marker.queue.add(the_mark);
        }

        /// Find `needle` in string and mark with `mark`.  Returns `true`
        /// if the needle was found and marked, otherwise `false`.
        pub fn findAndMark(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
        ) !bool {
            const idx = std.mem.indexOf(u8, marker.string, needle);
            if (idx) |i| {
                try marker.markFrom(mark, i, needle.len);
                return true;
            } else return false;
        }

        /// Find `needle` in string after `pos`, and mark with `mark`.
        /// Returns `true` if the needle was found and marked, `false`
        /// otherwise.
        pub fn findAndMarkPos(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
            pos: usize,
        ) !bool {
            const idx = std.mem.indexOfPos(u8, marker.string, pos, needle);
            if (idx) |i| {
                try marker.markFrom(mark, i, needle.len);
                return true;
            } else return false;
        }

        const LEFT: usize = 0;
        const RIGHT: usize = 1;

        /// Find last occurence of `needle` in string, and mark with
        /// `mark`.  Returns `true` if the needle was found and marked,
        /// `false` otherwise.
        pub fn findAndMarkLast(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
        ) !bool {
            const idx = std.mem.lastIndexOf(u8, marker.string, needle);
            if (idx) |i| {
                try marker.markFrom(mark, i, needle.len);
                return true;
            } else return false;
        }

        pub const StreamOption = enum {
            skip_on_zero_width,
            include_zero_width,
        };

        pub fn writeAsStream(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupArray,
        ) !void {
            return marker.writeAsStreamWithOption(
                writer,
                markups,
                .skip_on_zero_width,
            );
        }

        /// Write out the marked string as a stream: this is designed to
        /// work with protocols like ANSI terminal sequences, where the
        /// style signaling is in-band, and has to be repeated in order
        /// for nested colors to function correctly.  If emitting a tree-
        /// shaped markup syntax, such as XML or HTML, use `writeAsTree`.
        pub fn writeAsStreamWithOption(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupArray,
            option: StreamOption,
        ) !void {
            const no_zero = option == .skip_on_zero_width;
            // We use a second queue with a different comparison function, such
            // that the front of the queue is always the next-outermost Mark.
            const allocator = marker.queue.allocator;
            const string = marker.string;
            var in_q = marker.queue;
            var out_q = SweepQueue.init(allocator, {});
            defer out_q.deinit();
            // Some rounds of the while loop will skip a mark, so we pop the queue
            // manually:
            var this_mark = in_q.removeOrNull();
            var cursor: usize = 0;
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
                    try writer.writeAll(string[cursor..next_idx]);
                }
                cursor = next_idx;
                if (from_this_mark) {
                    // First we need to close the out mark, if there is one
                    if (maybe_next) |next| {
                        if (next.final() > mark.offset) {
                            if (!no_zero or (no_zero and next.offset < cursor)) {
                                const right = markups.get(next.kind)[RIGHT];
                                try writer.writeAll(right);
                            }
                        }
                    }
                    // Write our bookend.
                    // We might have a zero-width to skip though:
                    if (no_zero) {
                        const maybe_next_next = in_q.peek();
                        if (maybe_next_next) |next| {
                            if (next.offset == mark.offset) {
                                // Push the mark, but don't write it
                                try out_q.add(mark);
                                this_mark = in_q.remove();
                                continue :marking;
                            }
                        }
                    }
                    const left = markups.get(mark.kind)[LEFT];
                    try writer.writeAll(left);
                    // Enplace on the out queue.
                    try out_q.add(mark);
                    // Replace mark.
                    this_mark = in_q.removeOrNull();
                    continue :marking;
                } else {
                    // This mark isn't up yet, write the end off the queue.
                    const end_mark = out_q.remove();
                    const right = markups.get(end_mark.kind)[RIGHT];
                    try writer.writeAll(right);
                    // Now stream the left mark from the next on-queue, if any.
                    const maybe_left_mark = out_q.peek();
                    if (maybe_left_mark) |left_mark| {
                        if (no_zero and left_mark.final() == cursor) {
                            _ = out_q.remove();
                        } else {
                            const left = markups.get(left_mark.kind)[LEFT];
                            try writer.writeAll(left);
                        }
                    }
                    continue :marking;
                }
            } // end :marking
            // There may still be marks on the out queue to drain
            while (out_q.removeOrNull()) |out_mark| {
                const slice_end = out_mark.final();
                try writer.writeAll(string[cursor..slice_end]);
                cursor = slice_end;
                const right = markups.get(out_mark.kind)[RIGHT];
                try writer.writeAll(right);
                const maybe_left_mark = out_q.peek();
                if (maybe_left_mark) |left_mark| {
                    const left = markups.get(left_mark.kind)[LEFT];
                    try writer.writeAll(left);
                }
            }
            // Write the rest of the string, if any
            try writer.writeAll(string[cursor..]);

            return;
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
        /// so it only cares about offset + len.  The tie-breaker
        /// by enum is in the opposite order, so that two different
        /// enums of the same offset and len will be applied in the
        /// correct order, such that one nests within the other.
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
        \\[]obelizmo.MarkedString.Mark
        \\  [0]: obelizmo.MarkedString.Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .dee
        \\    .offset: u32 = 0
        \\    .len: u32 = 11
        \\  [1]: obelizmo.MarkedString.Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .la
        \\    .offset: u32 = 0
        \\    .len: u32 = 4
        \\  [2]: obelizmo.MarkedString.Mark
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

test "MarkedString.writeAsStream" {
    const oh = OhSnap{};
    const allocator = testing.allocator;
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
    var color_marker = try ColorMarker.initCapacity(allocator, "red blue green yellow", 4);
    defer color_marker.deinit();
    try expect(try color_marker.findAndMark(.red, "red"));
    try expect(try color_marker.findAndMark(.yellow, "yellow"));
    try expect(try color_marker.findAndMark(.green, "green"));
    try expect(try color_marker.findAndMark(.blue, "blue"));
    try color_marker.markSlice(.teal, 4, 14);
    try oh.snap(
        @src(),
        \\[]obelizmo.MarkedString.Mark
        \\  [0]: obelizmo.MarkedString.Mark
        \\    .kind: obelizmo.Colors
        \\      .red
        \\    .offset: u32 = 0
        \\    .len: u32 = 3
        \\  [1]: obelizmo.MarkedString.Mark
        \\    .kind: obelizmo.Colors
        \\      .teal
        \\    .offset: u32 = 4
        \\    .len: u32 = 10
        \\  [2]: obelizmo.MarkedString.Mark
        \\    .kind: obelizmo.Colors
        \\      .green
        \\    .offset: u32 = 9
        \\    .len: u32 = 5
        \\  [3]: obelizmo.MarkedString.Mark
        \\    .kind: obelizmo.Colors
        \\      .yellow
        \\    .offset: u32 = 15
        \\    .len: u32 = 6
        \\  [4]: obelizmo.MarkedString.Mark
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
    var writer = out_array.writer();
    try color_marker.writeAsStream(&writer, color_markup);
    const out_string = try out_array.toOwnedSlice();
    defer allocator.free(out_string);
    std.debug.print("{s}\n", .{out_string});
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>red</r> <b>blue</b><t> </t><g>green</g> <y>yellow</y>"
        ,
    ).expectEqual(out_string);
}
