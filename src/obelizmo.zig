const std = @import("std");
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue;
const Order = std.math.Order;

pub fn StringMarker(Kind: type) type {
    switch (@typeInfo(Kind)) {
        .Enum => {},
        else => @compileError("StringMarker must be given an enum"),
    }

    const Mark = struct {
        kind: Kind,
        offset: u32,
        len: u32,
    };

    const MarkedString = struct {
        string: []const u8,
        marks: []const Mark,
    };

    return struct {
        string: []const u8,
        queue: MarkQueue,

        const MarkQueue = PriorityQueue(Mark, void, compare);
        const SMark = @This();

        /// Initialize a StringMarker.  The string is not considered to be
        /// owned by the StringMarker, as such, the caller is responsible
        /// for its memory.  Call `marker.deinit()` to free the memory of
        /// the `StringMarker`.
        pub fn init(allocator: Allocator, string: []const u8) SMark {
            return SMark{
                .string = string,
                .queue = MarkQueue.init(allocator, {}),
            };
        }

        /// Initialize a StringMarker with a given capacity.  The string
        /// itself is not owned by the StringMarker, and the caller is
        /// responsible for managing it.  Call `marker.deinit()` to free
        /// the StringMarker.
        pub fn initCapacity(
            allocator: Allocator,
            string: []const u8,
            cap: usize,
        ) error{OutOfMemory}!SMark {
            const m_queue = MarkQueue.init(allocator, void);
            try m_queue.ensureTotalCapacity(cap);
            return SMark{
                .string = string,
                .queue = m_queue,
            };
        }

        /// Free memory allocated by the StringMarker.  The string is
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

        /// Turn the StringMarker into a MarkedString.  Copies the
        /// Marks, StringMarker must still be freed.
        pub fn toMarkedString(marker: *SMark) !MarkedString {
            const marks = try marker.queue.allocator.alloc(Mark, marker.queue.items.len);
            @memcpy(marks, marker.queue.items);
            return MarkedString{
                .string = marker.string,
                .marks = marks,
            };
        }

        /// Transfers ownership of the StringMarker's []Mark slice to
        /// a MarkedString.  Leaves the StringMarker in an invalid
        /// state, do not call `deinit`!
        pub fn toOwnedMarkedString(marker: *SMark) MarkedString {
            marker.queue.shrinkAndFree(marker.queue.items.len);
            return MarkedString{
                .string = marker.string,
                .marks = marker.queue.items,
            };
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
    };
}

//| TESTS

const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
const OhSnap = @import("ohsnap");

test "StringMarker" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};
    const e_num = enum {
        la,
        dee,
        dah,
    };
    const SM = StringMarker(e_num);
    // We don't free this because we borrow memory from it later
    var markup = SM.init(allocator, "blue green red");
    try markup.markSlice(.la, 0, 4);
    try markup.markSlice(.dee, 0, 11);
    try markup.markSlice(.dah, 11, 14);
    const marked_string = try markup.toMarkedString();
    defer allocator.free(marked_string.marks);
    try oh.snap(
        @src(),
        \\obelizmo.StringMarker.MarkedString
        \\  .string: []const u8
        \\    "blue green red"
        \\  .marks: []const obelizmo.StringMarker.Mark
        \\    [0]: obelizmo.StringMarker.Mark
        \\      .kind: obelizmo.test.StringMarker.e_num
        \\        .dee
        \\      .offset: u32 = 0
        \\      .len: u32 = 11
        \\    [1]: obelizmo.StringMarker.Mark
        \\      .kind: obelizmo.test.StringMarker.e_num
        \\        .la
        \\      .offset: u32 = 0
        \\      .len: u32 = 4
        \\    [2]: obelizmo.StringMarker.Mark
        \\      .kind: obelizmo.test.StringMarker.e_num
        \\        .dah
        \\      .offset: u32 = 11
        \\      .len: u32 = 3
        ,
    ).expectEqual(marked_string);
    const owned_marked = markup.toOwnedMarkedString();
    defer allocator.free(owned_marked.marks);
    try expectEqualSlices(
        @TypeOf(marked_string.marks[0]),
        marked_string.marks,
        owned_marked.marks,
    );
}

test "ohsnap is installed" {
    const four_tw0: u64 = 42;
    const oh = OhSnap{};
    try oh.snap(
        @src(),
        \\u64
        \\  42
        ,
    ).expectEqual(four_tw0);
}
