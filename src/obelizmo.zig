const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue;
const Order = std.math.Order;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const encoded_writer = @import("encoded_writer.zig");
const color_marks = @import("color_marks.zig");
const Color = color_marks.Color;

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
        pub const MarkupStringArray = std.enums.EnumArray(Kind, [2][]const u8);

        /// An EnumArray matching the enum type to instances of the Color union.
        /// To be used in terminal printing.
        pub const MarkupColorArray = std.enums.EnumArray(Kind, Color);

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
            markups: MarkupStringArray,
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

        /// Return a type which will print a `MarkedString` to a terminal,
        /// one line at a time.  Newlines are skipped, since in raw mode,
        /// there is no obvious placement of the cursor after a line is
        /// complete.
        ///
        /// Calling next() will return a boolean, until after the last
        /// line is printed, after which it will be `null`  You may or
        /// may not wish to print a final newline, whether or not the
        /// text happens to have one, so after the last line is complete,
        /// This value will be `false`.
        ///
        /// This is a fairly 'heavy' structure, which you may prefer to
        /// reuse: calling `line_writer.newText(&marked_string)` will
        /// replace the marked string and reset all necessary state.
        /// Call `line_writer.deinit()` to free all allocated memory,
        /// this will not include the MarkedString itself.
        pub fn XtermLineWriter(
            Writer: type,
        ) type {
            return struct {
                writer: Writer,
                marker: *const SMark,
                markups: MarkupColorArray,
                in_q: MarkQueue,
                out_q: OutQueue,
                fgs: ArrayListUnmanaged(Mark),
                bgs: ArrayListUnmanaged(Mark),
                uls: ArrayListUnmanaged(Mark),
                state: PrintState = .initial,
                cursor: usize = 0,
                next_index: usize = 0,
                this_mark: ?Mark = null,

                const XLine = @This();

                /// Initialize an XTermLineWriter. Free with xprint.deinit().
                pub fn init(
                    marker: *const SMark,
                    markups: MarkupColorArray,
                    writer: Writer,
                ) !XLine {
                    const alloc = marker.queue.allocator;
                    return XLine{
                        .writer = writer,
                        .markups = markups,
                        .in_q = try cloneQueue(marker.queue),
                        .out_q = OutQueue.init(alloc, {}),
                        .fgs = .empty,
                        .bgs = .empty,
                        .uls = .empty,
                    };
                }

                /// Free memory owned by the XTermLineWriter.  This does not
                /// include the MarkedString or MarkupColorArray.
                pub fn deinit(xprint: *XLine) void {
                    const alloc = xprint.marker.queue.allocator;
                    xprint.in_q.deinit();
                    xprint.out_q.deinit();
                    xprint.fgs.deinit(alloc);
                    xprint.bgs.deinit(alloc);
                    xprint.uls.deinit(alloc);
                }

                /// Provide the XTermLinePrinter with a new MarkedString.  This
                /// calls `reset` internally, after which the line printer is
                /// ready to be iterated over with `next`.
                pub fn newText(xprint: *XLine, markstring: *const SMark) !void {
                    xprint.marker = markstring;
                    try xprint.reset();
                }

                /// Resets the state of the XTermLinePrinter to its
                /// initial condition.
                pub fn reset(xprint: *XLine) !void {
                    xprint.in_q = try cloneQueue(xprint.marker.queue);
                    xprint.out_q.items.len = 0;
                    xprint.fgs.clearRetainingCapacity();
                    xprint.bgs.clearRetainingCapacity();
                    xprint.uls.clearRetainingCapacity();
                    xprint.state = .initial;
                    xprint.cursor = 0;
                    xprint.next_index = 0;
                    xprint.this_mark = null;
                }

                // Because this needs to restart, we need to create a
                // classic transformation from loop to state machine.
                //
                // What are the states?
                //
                // - Print-in-clear: before the first mark, and after
                //   the last out mark
                // - write-to-this: printing up to the end of this_mark
                // - write-to-out: printing up to the end of next_mark
                // - out-marks: draining the out mark queue
                //
                // So:
                //
                // A) Print everything before the first mark. State is
                // .print_to_first
                //
                // B) Print the printOn of the first mark, push it onto
                // the stack for its kind, put it in the out queue.
                //
                // C) Pull this_mark. Peek the out queue. If next_mark
                // is before the next out, set .write_this, otherwise
                // set .write_next.  Print what's between.
                //
                // If .write_this, execute B).
                //
                // If .write_next, pull off the out queue. If it's
                // stackable, it must be on top of its stack: remove.
                // Take the style beneath and printOn.
                //
                // Calculate the next index and set the state accordingly.
                //
                // When the in queue is drained, we're in .drain_out. Just
                // write until next_index, pull from out queue, pop stack,
                // write continuation, until out_queue is drained.
                //
                // Now it's .print_to_last: keep printing until everything
                // is done.  State is .final. The state .final returns null.
                //
                // Thus:
                const PrintState = enum {
                    initial,
                    this_mark,
                    write_this,
                    write_next,
                    next_mark,
                    drain,
                    last,
                    final,
                };

                pub fn next(xprint: *XLine) !bool {
                    var more: bool = true;
                    while (more) {
                        switch (xprint.state) {
                            .initial => more = try xprint.setup(),
                            .this_mark => more = try xprint.printThisMark(),
                            .write_this => more = try xprint.writeToThis(),
                            .write_next => more = try xprint.writeToNext(),
                            .next_mark => more = try xprint.printNextMark(),
                            .drain => more = try xprint.drainOutQueue(),
                            .last => more = try xprint.printLast(),
                            .final => return null,
                        }
                    }
                    if (xprint.state == .final)
                        return false
                    else
                        return true;
                }

                fn setup(xprint: *XLine) !bool {
                    // load this_mark, if any
                    const maybe_mark = xprint.in_q.removeOrNull();
                    if (maybe_mark) |mark| {
                        xprint.this_mark = mark;
                        xprint.state = .write_this;
                        xprint.next_index = mark.offset;
                    } else {
                        xprint.state = .last;
                        xprint.next_index = xprint.marker.string.len;
                    }
                    return true;
                }

                // Note: once this is up and running, we can
                // write logic which merges two Colors into
                // one for printing "on" and two for printing
                // "off".  Meanwhile redundant SGR is harmless.
                fn printThisMark(xprint: *XLine) !bool {
                    if (xprint.this_mark) |mark| {
                        const this_color = xprint.markups.get(mark.kind);
                        try this_color.printOn(xprint.writer);
                        // Push to correct stack
                        switch (this_color.style()) {
                            .style => {},
                            .foreground => {
                                try xprint.fgs.append(xprint.allocator(), mark);
                            },
                            .background => {
                                try xprint.bgs.append(xprint.allocator(), mark);
                            },
                            .underline => {
                                try xprint.uls.append(xprint.allocator(), mark);
                            },
                        }
                        // Append to out queue
                        try xprint.out_q.add(mark);
                        // Safety: we just added to the queue, so this
                        // always succeeds:
                        const next_mark = xprint.out_q.peek().?;
                        // Pull next mark
                        xprint.this_mark = xprint.in_q.removeOrNull();
                        if (xprint.this_mark) |this| {
                            if (this.offset <= next_mark.final()) {
                                xprint.state = .write_this;
                                xprint.next_index = this.offset;
                            } else {
                                xprint.state = .write_next;
                                xprint.next_index = next_mark.final();
                            }
                        } else {
                            xprint.next_index = next_mark.final();
                            xprint.state = .drain;
                        }
                    } else {
                        // Safety: `this_mark` is populated except for the `.drain`
                        // and `.last` states.
                        unreachable;
                    }
                    return true;
                }

                fn writeToThis(xprint: *XLine) !bool {
                    const did_line = try xprint.printUpTo();
                    if (did_line) return false;
                    xprint.state = .this_mark;
                    return true;
                }

                fn writeToNext(xprint: *XLine) !bool {
                    const did_line = try xprint.printUpTo();
                    if (did_line) return false;
                    xprint.state = .next_mark;
                    return true;
                }

                // This will be improved later, by combining a continuation mark
                // with the off-button on the next_mark Color.  Hence the common
                // printOff isn't lifted out of the switch.
                fn printNextMark(xprint: *XLine) !bool {
                    const next_mark = xprint.out_q.remove();
                    // Add assertion that cursor is correct (complex due to newlines)
                    const next_color = xprint.markups.get(next_mark.kind);
                    switch (next_color.style()) {
                        .style => {
                            try next_color.printOff(xprint.writer);
                        },
                        .foreground => {
                            try next_color.printOff(xprint.writer);
                            removeMarkFrom(xprint.fgs, next_mark);
                            const under_fg = xprint.fgs.getLastOrNull();
                            if (under_fg) |fg| {
                                const fg_next = xprint.markups.get(fg.kind);
                                try fg_next.printOn(xprint.writer);
                            }
                        },
                        .background => {
                            try next_color.printOff(xprint.writer);
                            removeMarkFrom(xprint.bgs, next_mark);
                            const under_bg = xprint.bgs.getLastOrNull();
                            if (under_bg) |bg| {
                                const bg_next = xprint.markups.get(bg.kind);
                                try bg_next.printOn(xprint.writer);
                            }
                        },
                        .underline => {
                            try next_color.printOff(xprint.writer);
                            removeMarkFrom(xprint.uls, next_mark);
                            const under_ul = xprint.uls.getLastOrNull();
                            if (under_ul) |ul| {
                                const ul_next = xprint.markups.get(ul.kind);
                                try ul_next.printOn(xprint.writer);
                            }
                        },
                    }
                    // Determine following state and index.
                    // .drain uses this function, so these can both be null:
                    const maybe_this = xprint.this_mark;
                    const maybe_next = xprint.out_q.peek();
                    if (maybe_next) |next_after| {
                        if (maybe_this) |this_mark| {
                            if (this_mark.offset <= next_after.final()) {
                                xprint.state = .write_this;
                                xprint.next_index = this_mark.offset;
                            } else {
                                xprint.state = .write_next;
                                xprint.next_index = next_after.final();
                            }
                        } else {
                            // TODO: maybe drain is redundant?
                            xprint.state = .drain;
                            xprint.next_index = next_after.final();
                        }
                    } else {
                        if (maybe_this) |this_mark| {
                            xprint.state = .write_this;
                            xprint.next_index = this_mark.offset;
                        } else {
                            xprint.state = .last;
                            xprint.next_index = xprint.marker.string.len;
                        }
                    }
                    return true;
                }

                fn drainOutQueue(xprint: *XLine) !bool {
                    const did_line = try xprint.printUpTo();
                    if (did_line) return false;
                    xprint.state = .write_next;
                    return true;
                }

                fn printLast(xprint: *XLine) !bool {
                    if (xprint.cursor >= xprint.marker.string.len) {
                        xprint.state = .final;
                        return true;
                    }
                    const did_line = try xprint.printUpTo();
                    if (did_line) return false;
                    xprint.state = .final;
                    return true;
                }

                fn printUpTo(xprint: *XLine) !bool {
                    const start = xprint.cursor;
                    while (xprint.cursor < xprint.next_index) : (xprint.cursor += 1) {
                        const b = xprint.marker.string[xprint.cursor];
                        if (b == '\n' or b == '\r') {
                            try xprint.writer.write(xprint.marker.string[start..xprint.cursor]);
                            const n = if (xprint.cursor + 1 < xprint.marker.string.len)
                                xprint.marker.string[xprint.cursor + 1]
                            else
                                '!'; // random sentinel
                            // Safety: we ensure that next_index is never greater than
                            // the string length, so when these go beyond bounds, we
                            // cannot reach this code path.
                            if (b == '\r' and n == '\n') {
                                xprint.cursor += 2;
                            } else {
                                xprint.cursor += 1;
                            }
                            return true;
                        }
                    }
                    try xprint.writer.write(xprint.marker.string[start..xprint.cursor]);
                    return false;
                }

                fn removeMarkFrom(mark_list: ArrayListUnmanaged(Mark), mark: Mark) void {
                    const marks = mark_list.items;
                    var idx = marks.len - 1;
                    while (idx >= 0) : (idx -= 1) {
                        const a_mark = marks[idx];
                        if (std.meta.eql(a_mark, mark)) break;
                    }
                    const removed = mark_list.orderedRemove(idx);
                    assert(std.meta.eql(removed, mark));
                }

                inline fn allocator(xprint: XLine) Allocator {
                    return xprint.marker.queue.allocator;
                }
            };
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
            markups: MarkupStringArray,
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
//|

const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
const expectEqualStrings = testing.expectEqualStrings;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const OhSnap = struct {}; // @import("ohsnap");

test "MarkedString" {
    if (true)
        return error.SkipZigTest;
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
    ).expectEqual(SM.MarkupStringArray);
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
const ColorArray = ColorMarker.MarkupStringArray;
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
    if (true)
        return error.SkipZigTest;
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
    if (true)
        return error.SkipZigTest;
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
