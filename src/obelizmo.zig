const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue;
const Order = std.math.Order;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const encoded_writer = @import("encoded_writer.zig");
const xcolors = @import("colors");

pub usingnamespace xcolors;

pub const Color = xcolors.Color;
pub const ErrorOf = xcolors.ErrorOf;

pub const EncodedWriter = encoded_writer.EncodedWriter;
pub const HtmlEncodedWriter = encoded_writer.HtmlEncodedWriter;
pub const DefaultEncodedWriter = encoded_writer.DefaultEncodedWriter;
pub const XtermEncodedWriter = encoded_writer.XtermEncodedWriter;

pub fn MarkedString(Kind: type) type {
    switch (@typeInfo(Kind)) {
        .@"enum" => {},
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
        pub const MarkQueue = PriorityQueue(Mark, void, compareInQueue);

        /// Queue for writing `Marks`.
        pub const OutQueue = PriorityQueue(Mark, void, compareOutQueue);

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

        /// Remove the first mark encountered of the provided enum kind.
        /// This is the first mark in heap order, which will not consistently
        /// be the first mark on the string.  Returns the mark when found,
        /// or `null` otherwise.
        pub fn removeMark(marker: *SMark, mark: Kind) ?Mark {
            for (marker.queue.items, 0..) |item, i| {
                if (item.kind == mark) {
                    return marker.queue.removeIndex(i);
                }
            }
            return null;
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

        fn sameQueue(q1: MarkQueue, q2: MarkQueue) bool {
            return @intFromPtr(q1.items.ptr) == @intFromPtr(q2.items.ptr);
        }

        const LEFT: usize = 0;
        const RIGHT: usize = 1;

        /// Return a type which will print a `MarkedString` to a terminal,
        /// one line at a time.  Newlines are skipped, since in raw mode,
        /// there is no obvious placement of the cursor after a line is
        /// complete.
        ///
        /// Calling next() will return a boolean, until after the last
        /// line is printed, after which it will be `null`.  The return
        /// value will be `true` until the last line, when it becomes
        /// `false`; this will happen whether or not a string has a
        /// terminal newline, since whether or a not a TUI wants a final
        /// newline is broadly independent of whether or not the string
        /// happens to have one.
        ///
        /// This is a fairly 'heavy' structure, which you may prefer to
        /// reuse: calling `line_writer.newText(&marked_string)` will
        /// replace the marked string and reset all necessary state.
        /// Call `line_writer.deinit()` to free all allocated memory,
        /// this will not include the MarkedString itself.  The allocator
        /// itself is reused from the MarkedString.
        ///
        pub fn XtermLineWriter(
            Writer: type,
        ) type {
            return struct {
                writer: Writer,
                marker: *const SMark,
                markups: MarkupColorArray,
                /// Represents the point in the marked string after printing.
                cursor: usize = 0,
                // The remaining fields are internal, and should
                // not be considered stable API
                in_q: MarkQueue,
                out_q: OutQueue,
                fgs: ArrayListUnmanaged(Mark),
                bgs: ArrayListUnmanaged(Mark),
                uls: ArrayListUnmanaged(Mark),
                state: PrintState = .initial,
                next_index: usize = 0,
                this_mark: ?Mark = null,

                const XLine = @This();

                const can_encode = encode: {
                    const write_info = @typeInfo(Writer);
                    switch (write_info) {
                        .pointer => {
                            break :encode @hasDecl(std.meta.Child(Writer), "writeEncode");
                        },
                        .@"struct" => {
                            break :encode @hasDecl(Writer, "writeEncode");
                        },
                        // This can fail later, it's fine
                        else => break :encode false,
                    }
                };

                pub const Error = ErrorOf(Writer) || error{OutOfMemory};

                /// Initialize an XTermLineWriter. Free with xprint.deinit().
                pub fn init(
                    marker: *const SMark,
                    markups: MarkupColorArray,
                    writer: Writer,
                ) XLine {
                    const alloc = marker.queue.allocator;
                    return XLine{
                        .writer = writer,
                        .marker = marker,
                        .markups = markups,
                        // This a useful placeholder, we clone from the .initial state.
                        .in_q = marker.queue,
                        .out_q = OutQueue.init(alloc, {}),
                        .fgs = .empty,
                        .bgs = .empty,
                        .uls = .empty,
                    };
                }

                /// Initialize an XTermLineWriter. Free with xprint.deinit().
                /// This initializer consumes the marked string, which is left
                /// in a valid state but bereft of marks.  It must still be freed.
                /// It is legal to reset() this and print again, but no marks will
                /// be evident.
                pub fn initOnce(
                    marker: *const SMark,
                    markups: MarkupColorArray,
                    writer: Writer,
                ) XLine {
                    const alloc = marker.queue.allocator;
                    return XLine{
                        .writer = writer,
                        .marker = marker,
                        .markups = markups,
                        .in_q = marker.queue,
                        .out_q = OutQueue.init(alloc, {}),
                        .fgs = .empty,
                        .bgs = .empty,
                        .uls = .empty,
                        .state = .initial_consume,
                    };
                }

                /// Free memory owned by the XTermLineWriter.  This does not
                /// include the MarkedString or MarkupColorArray.
                pub fn deinit(xprint: *XLine) void {
                    const alloc = xprint.marker.queue.allocator;
                    if (xprint.state != .initial and
                        !sameQueue(xprint.marker.queue, xprint.in_q))
                    {
                        xprint.in_q.deinit();
                    }
                    xprint.out_q.deinit();
                    xprint.fgs.deinit(alloc);
                    xprint.bgs.deinit(alloc);
                    xprint.uls.deinit(alloc);
                }

                /// Provide the XtermLinePrinter with a new MarkedString.  This
                /// calls `reset` internally, after which the line printer is
                /// ready to be iterated over with `next`.
                pub fn newText(xprint: *XLine, markstring: *const SMark) void {
                    xprint.marker = markstring;
                    xprint.reset();
                }

                /// Provide the XtermLinePrinter with a new MarkedString.  This will
                /// be printed destructively, un-marking the MarkedString in the
                /// process.  It is left in a valid but empty state, and must still
                /// be freed: the new text may be printed again, but will have no marks.
                pub fn newTextOnce(xprint: *XLine, markstring: *const SMark) void {
                    xprint.marker = markstring;
                    xprint.reset();
                    xprint.state = .initial_consume;
                    xprint.in_q = markstring.queue;
                }

                /// Resets the state of the XTermLinePrinter to its
                /// initial condition.
                pub fn reset(xprint: *XLine) void {
                    if (xprint.state != .initial and
                        !sameQueue(xprint.marker.queue, xprint.in_q))
                    {
                        xprint.in_q.deinit();
                    }
                    xprint.out_q.items.len = 0;
                    xprint.fgs.clearRetainingCapacity();
                    xprint.bgs.clearRetainingCapacity();
                    xprint.uls.clearRetainingCapacity();
                    xprint.state = .initial;
                    xprint.cursor = 0;
                    xprint.next_index = 0;
                    xprint.this_mark = null;
                }

                /// Because this needs to restart, we base it around a
                /// classic state machine.
                ///
                /// These are those states:
                const PrintState = enum {
                    /// Initialize to consume the mark queue.
                    initial_consume,
                    /// Initialize, cloning the mark queue.
                    initial,
                    /// Resume printing after a seek or drop.
                    resume_print,
                    /// Print this_mark.
                    this_mark,
                    /// Write up to next_index, then print this_mark.
                    write_to_this,
                    /// Write up to next_index, then print the next mark from out_q.
                    write_to_next,
                    /// Print the next mark from out_q.
                    next_mark,
                    /// Done with mark, just print lines.
                    last,
                    /// Printing has completed.
                    final,
                };

                /// Print the next line.  Returns `true` until there are
                /// no more lines to print, then `false`.  Subsequent calls
                /// will return `null`.  You do not need to call `next()`
                /// again if `false` is returned.
                pub fn next(xprint: *XLine) Error!?bool {
                    if (xprint.state == .final) return null;
                    var more: bool = true;
                    while (more) {
                        switch (xprint.state) {
                            .initial_consume => more = try xprint.setup(false),
                            .initial => more = try xprint.setup(true),
                            .resume_print => more = try xprint.resumePrint(),
                            .this_mark => more = try xprint.printThisMark(),
                            .write_to_this => more = try xprint.writeToThis(),
                            .write_to_next => more = try xprint.writeToNext(),
                            .next_mark => more = try xprint.printNextMark(),
                            .last => more = try xprint.printLast(),
                            .final => return false,
                        }
                    }
                    return true;
                }

                pub const SeekError = error{ BeforeIndex, IndexTooLarge, OutOfMemory };

                /// Seek the printer forward to `index`.  Errors are thrown if `index` is
                /// less than the span already printed, or greater than the string length.
                /// Prints nothing until `next` is called again, when it will start any
                /// terminal codes needed, after resetting any which happened to be in
                /// play.  Return whether there's more to print, or `null` if the print
                /// was already complete.  Note that to properly terminate a print using
                /// this function, you must call `next` even when `false`, but not `null`,
                /// is returned.
                pub fn seek(xprint: *XLine, index: usize) SeekError!?bool {
                    // Erroneous inputs.
                    if (index > xprint.marker.string.len) {
                        return error.IndexTooLarge;
                    } else if (xprint.cursor > index) {
                        return error.BeforeIndex;
                    }
                    // Boundary conditions.
                    switch (xprint.state) {
                        .initial, .initial_consume => |tag| {
                            const which = tag == .initial;
                            _ = try xprint.setup(which);
                        },
                        .final => return null,
                        else => {},
                    }
                    if (index == xprint.marker.string.len) {
                        xprint.in_q.shrinkAndFree(0);
                        xprint.out_q.shrinkAndFree(0);
                        xprint.state = .final;
                        xprint.cursor = index;
                        return false;
                    }

                    // We need to handle both the in queue and the out queue:

                    // The out queue needs to be stripped of anything which will
                    // terminate (mark.final()) before our mark, and, when applicable,
                    // those must be removed from the stacks as well.
                    var seek_out = xprint.out_q.peek();
                    while (seek_out) |out_mark| {
                        if (out_mark.final() > index) {
                            const color = xprint.markups.get(out_mark.kind);
                            switch (color.style()) {
                                .effect => {},
                                .foreground => removeMarkFrom(&xprint.fgs, out_mark),
                                .background => removeMarkFrom(&xprint.bgs, out_mark),
                                .underline => removeMarkFrom(&xprint.uls, out_mark),
                            }
                            _ = xprint.out_q.remove();
                            seek_out = xprint.out_q.peek();
                        } else break;
                    }
                    // Then we must do the same to the in queue, stacking up anything which
                    // must be on when we resume, and dropping anything which needs dropping.
                    // One wrinkle: we don't have a stack for effects, so we make one.  These
                    // are put back on the in_q, the restart function has special logic to
                    // handle this condition.
                    var effect_stack: ArrayListUnmanaged(Mark) = .empty;
                    defer effect_stack.deinit(xprint.allocator());
                    // Start with this_mark, if present
                    var maybe_mark = xprint.this_mark orelse xprint.in_q.removeOrNull();
                    while (maybe_mark) |a_mark| {
                        if (a_mark.offset >= index) {
                            // We have our mark.
                            xprint.this_mark = a_mark;
                            xprint.state = .resume_print;
                            xprint.cursor = index;
                            for (effect_stack.items) |style_mark| {
                                try xprint.in_q.add(style_mark);
                            }
                            return true;
                        }
                        if (a_mark.final() > index) {
                            const mark_color = xprint.markups.get(a_mark.kind);
                            switch (mark_color.style()) {
                                .effect => {
                                    // put it on the style stack
                                    try effect_stack.append(xprint.allocator(), a_mark);
                                },
                                .foreground => {
                                    try xprint.fgs.append(xprint.allocator(), a_mark);
                                },
                                .background => {
                                    try xprint.bgs.append(xprint.allocator(), a_mark);
                                },
                                .underline => {
                                    try xprint.uls.append(xprint.allocator(), a_mark);
                                },
                            }
                            try xprint.out_q.add(a_mark);
                            maybe_mark = xprint.in_q.removeOrNull();
                        } else {
                            // We've completely passed this mark.
                            maybe_mark = xprint.in_q.removeOrNull();
                        }
                    }
                    // Getting here means we've emptied in_q, except maybe the style stack.
                    assert(xprint.in_q.items.len == 0);
                    for (effect_stack.items) |style_mark| {
                        try xprint.in_q.add(style_mark);
                    }
                    xprint.state = .resume_print;
                    xprint.cursor = index;
                    return true;
                }

                /// Drop the next line without printing it.  Answers `true`
                /// if there are subsequent lines, `false` if it dropped the
                /// last line, and `null` if there are no lines left to drop.
                /// Note that to properly terminate a print using this function,
                /// you must call `next` even when `false`, but not `null`,
                /// is returned.
                pub fn drop(xprint: *XLine) error{OutOfMemory}!?bool {
                    if (xprint.state == .final) return null;

                    const next_nl = std.mem.indexOfScalarPos(
                        u8,
                        xprint.marker.string,
                        xprint.cursor,
                        '\n',
                    );
                    if (next_nl) |nl_idx| {
                        return xprint.seek(nl_idx + 1) catch |err| {
                            switch (err) {
                                // String.len is valid, so neither of these can happen:
                                error.BeforeIndex, error.IndexTooLarge => unreachable,
                                error.OutOfMemory => |e| return e,
                            }
                        };
                    } else {
                        xprint.state = .last;
                        xprint.cursor = xprint.marker.string.len;
                        return false;
                    }
                }

                /// Drop the next `nlines` without printing them.  For further
                /// details, see the documentation for `xprint.drop`.
                pub fn dropN(xprint: *XLine, nlines: usize) error{OutOfMemory}!?bool {
                    var drop_bool: ?bool = null;
                    for (0..nlines) |_| {
                        drop_bool = try xprint.drop();
                    }
                    return drop_bool;
                }

                //| Implementation details (not part of API)

                fn setup(xprint: *XLine, clone: bool) error{OutOfMemory}!bool {
                    // Clone queue.
                    if (clone) {
                        xprint.in_q = try cloneQueue(xprint.marker.queue);
                    }
                    // load this_mark, if any
                    const maybe_mark = xprint.in_q.removeOrNull();
                    if (maybe_mark) |mark| {
                        xprint.this_mark = mark;
                        xprint.state = .write_to_this;
                        xprint.next_index = mark.offset;
                    } else {
                        xprint.state = .last;
                        xprint.next_index = xprint.marker.string.len;
                    }
                    return true;
                }

                fn resumePrint(xprint: *XLine) Error!bool {
                    // Clean slate:
                    try xprint.writer.writeAll("\x1b[0m");
                    // Styles on the in_q?
                    var maybe_back = xprint.in_q.peek();
                    while (maybe_back) |back_mark| {
                        if (back_mark.offset >= xprint.cursor) break;
                        const back_color = xprint.markups.get(back_mark.kind);
                        assert(back_color.style() == .effect);
                        try back_color.printOn(xprint.writer);
                        _ = xprint.in_q.remove();
                        maybe_back = xprint.in_q.peek();
                    }
                    // Anything on the stacks?

                    // Because foreground colors might carry styles,
                    // and styles (e.g. italic) carry over into other colors,
                    // we apply everything we have, from bottom to top.
                    for (xprint.fgs.items) |fg_mark| {
                        try xprint.markups.get(fg_mark.kind).printOn(xprint.writer);
                    }
                    // Background and underline only need to print the latest, if any.
                    const maybe_bg = xprint.bgs.getLastOrNull();
                    if (maybe_bg) |bg_mark| {
                        try xprint.markups.get(bg_mark.kind).printOn(xprint.writer);
                    }
                    const maybe_ul = xprint.uls.getLastOrNull();
                    if (maybe_ul) |ul_mark| {
                        try xprint.markups.get(ul_mark.kind).printOn(xprint.writer);
                    }
                    // Last, determine the state we need to be in.  The options are
                    // write_to_this, write_to_next, and last, since the first two can
                    // print a null string if they need to.
                    const maybe_next = xprint.out_q.peek();
                    if (xprint.this_mark) |the_mark| {
                        if (maybe_next) |next_mark| {
                            if (next_mark.final() >= the_mark.offset) {
                                xprint.state = .write_to_this;
                                xprint.next_index = the_mark.offset;
                                return true;
                            } else {
                                xprint.state = .write_to_next;
                                xprint.next_index = next_mark.final();
                                return true;
                            }
                        } else {
                            xprint.state = .write_to_this;
                            xprint.next_index = the_mark.offset;
                            return true;
                        }
                    } else {
                        if (maybe_next) |next_mark| {
                            xprint.state = .write_to_next;
                            xprint.next_index = next_mark.final();
                            return true;
                        } else {
                            xprint.state = .last;
                            xprint.next_index = xprint.marker.string.len;
                            return true;
                        }
                    }
                    comptime unreachable;
                }

                fn printThisMark(xprint: *XLine) Error!bool {
                    // Safety: `this_mark` is populated every time this
                    // state is reached.
                    const mark = xprint.this_mark.?;
                    const this_color = xprint.markups.get(mark.kind);
                    try this_color.printOn(xprint.writer);
                    // Push to correct stack
                    switch (this_color.style()) {
                        .effect => {},
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
                            xprint.state = .write_to_this;
                            xprint.next_index = this.offset;
                        } else {
                            xprint.state = .write_to_next;
                            xprint.next_index = next_mark.final();
                        }
                    } else {
                        xprint.state = .write_to_next;
                        xprint.next_index = next_mark.final();
                    }
                    return true;
                }

                fn writeToThis(xprint: *XLine) Error!bool {
                    const did_line = try xprint.printUpTo();
                    if (did_line) return false;
                    xprint.state = .this_mark;
                    return true;
                }

                fn writeToNext(xprint: *XLine) Error!bool {
                    const did_line = try xprint.printUpTo();
                    if (did_line) return false;
                    xprint.state = .next_mark;
                    return true;
                }

                // This will be improved later, by combining a continuation mark
                // with the off-button on the next_mark Color.  Hence the common
                // printOff isn't lifted out of the switch.
                fn printNextMark(xprint: *XLine) Error!bool {
                    const next_mark = xprint.out_q.remove();
                    // Add assertion that cursor is correct (complex due to newlines)
                    const next_color = xprint.markups.get(next_mark.kind);
                    switch (next_color.style()) {
                        .effect => {
                            try next_color.printOff(xprint.writer);
                        },
                        .foreground => {
                            try next_color.printOff(xprint.writer);
                            removeMarkFrom(&xprint.fgs, next_mark);
                            const under_fg = xprint.fgs.getLastOrNull();
                            if (under_fg) |fg| {
                                const fg_next = xprint.markups.get(fg.kind);
                                try fg_next.printOn(xprint.writer);
                            }
                        },
                        .background => {
                            try next_color.printOff(xprint.writer);
                            removeMarkFrom(&xprint.bgs, next_mark);
                            const under_bg = xprint.bgs.getLastOrNull();
                            if (under_bg) |bg| {
                                const bg_next = xprint.markups.get(bg.kind);
                                try bg_next.printOn(xprint.writer);
                            }
                        },
                        .underline => {
                            try next_color.printOff(xprint.writer);
                            removeMarkFrom(&xprint.uls, next_mark);
                            const under_ul = xprint.uls.getLastOrNull();
                            if (under_ul) |ul| {
                                const ul_next = xprint.markups.get(ul.kind);
                                try ul_next.printOn(xprint.writer);
                            }
                        },
                    }
                    // Determine following state and index.
                    // These can both be null:
                    const maybe_this = xprint.this_mark;
                    const maybe_next = xprint.out_q.peek();
                    if (maybe_next) |next_after| {
                        if (maybe_this) |this_mark| {
                            if (this_mark.offset <= next_after.final()) {
                                xprint.state = .write_to_this;
                                xprint.next_index = this_mark.offset;
                            } else {
                                xprint.state = .write_to_next;
                                xprint.next_index = next_after.final();
                            }
                        } else {
                            xprint.state = .write_to_next;
                            xprint.next_index = next_after.final();
                        }
                    } else {
                        if (maybe_this) |this_mark| {
                            xprint.state = .write_to_this;
                            xprint.next_index = this_mark.offset;
                        } else {
                            xprint.state = .last;
                            xprint.next_index = xprint.marker.string.len;
                        }
                    }
                    return true;
                }

                fn printLast(xprint: *XLine) Error!bool {
                    if (xprint.cursor >= xprint.marker.string.len) {
                        xprint.state = .final;
                        return true;
                    }
                    const did_line = try xprint.printUpTo();
                    if (did_line) {
                        // Check for final newline
                        if (xprint.cursor == xprint.marker.string.len and
                            xprint.marker.string[xprint.cursor - 1] == '\n')
                        {
                            xprint.state = .final;
                        }
                        return false;
                    }
                    xprint.state = .final;
                    return true;
                }

                fn printUpTo(xprint: *XLine) Error!bool {
                    const start = xprint.cursor;
                    while (xprint.cursor < xprint.next_index) : (xprint.cursor += 1) {
                        const b = xprint.marker.string[xprint.cursor];
                        if (b == '\n' or b == '\r') {
                            if (can_encode) {
                                _ = try xprint.writer.writeEncode(xprint.marker.string[start..xprint.cursor]);
                            } else {
                                try xprint.writer.writeAll(xprint.marker.string[start..xprint.cursor]);
                            }
                            const n: u8 = if (xprint.cursor + 1 < xprint.marker.string.len)
                                xprint.marker.string[xprint.cursor + 1]
                            else
                                '!'; // just a sentinel
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
                    } // If we exceeded the index (due to the logic above), then this is empty:
                    if (can_encode) {
                        _ = try xprint.writer.writeEncode(xprint.marker.string[start..xprint.cursor]);
                    } else {
                        try xprint.writer.writeAll(xprint.marker.string[start..xprint.cursor]);
                    }
                    return false;
                }

                /// Remove the mark from the ArrayList stack.  Mark must be present.
                fn removeMarkFrom(mark_list: *ArrayListUnmanaged(Mark), mark: Mark) void {
                    const marks = mark_list.items;
                    var idx = marks.len - 1;
                    while (idx >= 0) : (idx -= 1) {
                        const a_mark = marks[idx];
                        if (std.meta.eql(a_mark, mark)) break;
                        // Rather than panic on underflow:
                        if (idx == 0) @panic("mark not found in its stack");
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
        /// For that purpose, use an `XtermLineWriter`.  See `EncodedWriter`
        /// for information on how to escape the string text for your format.
        /// For HTML, an HTMLEncodedWriter is provided.
        pub fn writeAsTree(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupStringArray,
        ) ErrorOf(@TypeOf(writer))!usize {
            // See if there's a writeEncode function.
            const writeBody = encode: {
                const Writer = @TypeOf(writer);
                const write_info = @typeInfo(Writer);
                switch (write_info) {
                    .pointer => {
                        if (@hasDecl(std.meta.Child(Writer), "writeEncode")) {
                            break :encode std.meta.Child(Writer).writeEncode;
                        } else {
                            break :encode std.meta.Child(Writer).write;
                        }
                    },
                    .@"struct" => {
                        if (@hasDecl(Writer, "writeEncode")) {
                            break :encode Writer.writeEncode;
                        } else {
                            break :encode Writer.write;
                        }
                    },
                    else => unreachable,
                }
            };
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
        fn compareInQueue(_: void, left: Mark, right: Mark) Order {
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
        fn compareOutQueue(_: void, left: Mark, right: Mark) Order {
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
const esc_string = @import("ezcaper").escStringExact;

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
        \\[]obelizmo.MarkedString(obelizmo.test.MarkedString.e_num).Mark
        \\  [0]: obelizmo.MarkedString(obelizmo.test.MarkedString.e_num).Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .dee
        \\    .offset: u32 = 0
        \\    .len: u32 = 11
        \\  [1]: obelizmo.MarkedString(obelizmo.test.MarkedString.e_num).Mark
        \\    .kind: obelizmo.test.MarkedString.e_num
        \\      .la
        \\    .offset: u32 = 0
        \\    .len: u32 = 4
        \\  [2]: obelizmo.MarkedString(obelizmo.test.MarkedString.e_num).Mark
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

const TestColors = enum {
    red,
    blue,
    green,
    yellow,
    teal,
    // etc
};

const ColorMarker = MarkedString(TestColors);
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
        \\[]obelizmo.MarkedString(obelizmo.TestColors).Mark
        \\  [0]: obelizmo.MarkedString(obelizmo.TestColors).Mark
        \\    .kind: obelizmo.TestColors
        \\      .red
        \\    .offset: u32 = 0
        \\    .len: u32 = 3
        \\  [1]: obelizmo.MarkedString(obelizmo.TestColors).Mark
        \\    .kind: obelizmo.TestColors
        \\      .teal
        \\    .offset: u32 = 4
        \\    .len: u32 = 10
        \\  [2]: obelizmo.MarkedString(obelizmo.TestColors).Mark
        \\    .kind: obelizmo.TestColors
        \\      .green
        \\    .offset: u32 = 9
        \\    .len: u32 = 5
        \\  [3]: obelizmo.MarkedString(obelizmo.TestColors).Mark
        \\    .kind: obelizmo.TestColors
        \\      .yellow
        \\    .offset: u32 = 15
        \\    .len: u32 = 6
        \\  [4]: obelizmo.MarkedString(obelizmo.TestColors).Mark
        \\    .kind: obelizmo.TestColors
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

const XColor = enum {
    reset_italic,
    blue,
    green,
    forty_two,
    red_italic_bold,
    green_underline,
    purple_curly_underline,
    tan_background,
    default_background,
    inverse,
    black,
    super_magenta,
    bg_grey69,
    dashed_orange1,
};

const XColorMarker = MarkedString(XColor);
const XColorArray = XColorMarker.MarkupColorArray;

const x_markups = XColorArray.init(
    .{
        .reset_italic = xcolors.reset().upright(),
        .blue = xcolors.fgBasic(.blue),
        .green = xcolors.fgBasic(.green),
        .forty_two = xcolors.fg256(42),
        .red_italic_bold = xcolors.fgRgb(255, 0, 0).italic().bold(),
        .green_underline = xcolors.ulBasic(.single, .green),
        .purple_curly_underline = xcolors.ulRgb(.curly, 178, 40, 222),
        .tan_background = xcolors.bgRgb(247, 228, 169),
        .default_background = xcolors.bgDefault(),
        .inverse = xcolors.inverse(),
        .black = xcolors.fgBasic(.black),
        .super_magenta = xcolors.fgBasic(.magenta).superScript(),
        .bg_grey69 = xcolors.bg256(145),
        .dashed_orange1 = xcolors.ul256(.dashed, 214),
    },
);

const x_string =
    \\aaa111333111aaa
    \\(foo bar bazbux) quux
    \\---|||!!!|||---
    \\
    \\
;

const reg_a = Regex.compile("aaa.*?aaa").?;
const reg_1 = Regex.compile("111.*?111").?;
const reg_paren = Regex.compile("\\(.*?\\)").?;
const reg_dash = Regex.compile("---.*?---").?;
const reg_bar = Regex.compile("\\|\\|\\|.*?\\|\\|\\|").?;

test "XLine" {
    const allocator = std.testing.allocator;
    const oh: OhSnap = .{};
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    const writer = out_array.writer();
    const XLine = XColorMarker.XtermLineWriter(@TypeOf(&writer));
    var marked = XColorMarker.init(allocator, x_string);
    defer marked.deinit();
    var xprint = XLine.init(&marked, x_markups, &writer);
    _ = try marked.matchAndMark(.red_italic_bold, reg_a);
    _ = try marked.matchAndMark(.green_underline, reg_1);
    // _ = try marked.findAndMark(.purple_curly_underline, "333");
    _ = try marked.findAndMark(.reset_italic, "333");
    _ = try marked.findAndMark(.green, "333");
    _ = try marked.matchAndMark(.tan_background, reg_paren);
    _ = try marked.matchAndMark(.black, reg_paren);
    _ = try marked.findAndMark(.blue, "foo bar baz");
    _ = try marked.findAndMark(.inverse, "uu");
    _ = try marked.findAndMark(.green, "quux");
    _ = try marked.findAndMark(.super_magenta, "!!!");
    _ = try marked.matchAndMark(.bg_grey69, reg_bar);
    _ = try marked.matchAndMark(.dashed_orange1, reg_dash);
    defer xprint.deinit();
    {
        while (try xprint.next()) |_| {}
        const line = try out_array.toOwnedSlice();
        defer allocator.free(line);
        try oh.snap(
            @src(),
            \\"\x1b[1m\x1b[3m\x1b[38:2:255:0:0maaa\x1b[4m\x1b[58:5:2m111\x1b[23m\x1b[32m333\x1b[39m\x1b[1m\x1b[3m\x1b[38:2:255:0:0m111\x1b[59m\x1b[24maaa\x1b[22m\x1b[23m\x1b[39m\x1b[48:2:247:228:169m\x1b[30m(\x1b[34mfoo bar baz\x1b[39m\x1b[30mbux)\x1b[39m\x1b[49m \x1b[32mq\x1b[7muu\x1b[27mx\x1b[39m\x1b[4:5m\x1b[58:5:214m---\x1b[48:5:145m|||\x1b[73m\x1b[35m!!!\x1b[75m\x1b[39m|||\x1b[49m---\x1b[59m\x1b[24m"
            ,
        ).expectEqualFmt(esc_string(line));
    }
    // Prints unmarked string properly.
    var empty_mark = XColorMarker.init(allocator, x_string);
    defer empty_mark.deinit();
    xprint.newText(&empty_mark);
    {
        while (try xprint.next()) |_| {}
        const line = try out_array.toOwnedSlice();
        defer allocator.free(line);
        try oh.snap(
            @src(),
            \\"aaa111333111aaa(foo bar bazbux) quux---|||!!!|||---"
            ,
        ).expectEqualFmt(esc_string(line));
    }
    // Seek tests
    xprint.newText(&marked);
    _ = try xprint.seek(6);
    {
        while (try xprint.next()) |_| {}
        const line = try out_array.toOwnedSlice();
        defer allocator.free(line);
        try oh.snap(
            @src(),
            \\"\x1b[0m\x1b[1m\x1b[3m\x1b[38:2:255:0:0m\x1b[4m\x1b[58:5:2m\x1b[23m\x1b[32m333\x1b[39m\x1b[1m\x1b[3m\x1b[38:2:255:0:0m111\x1b[59m\x1b[24maaa\x1b[22m\x1b[23m\x1b[39m\x1b[48:2:247:228:169m\x1b[30m(\x1b[34mfoo bar baz\x1b[39m\x1b[30mbux)\x1b[39m\x1b[49m \x1b[32mq\x1b[7muu\x1b[27mx\x1b[39m\x1b[4:5m\x1b[58:5:214m---\x1b[48:5:145m|||\x1b[73m\x1b[35m!!!\x1b[75m\x1b[39m|||\x1b[49m---\x1b[59m\x1b[24m"
            ,
        ).expectEqualFmt(esc_string(line));
    }
    xprint.newText(&marked);
    _ = try xprint.seek(25);
    {
        while (try xprint.next()) |_| {}
        const line = try out_array.toOwnedSlice();
        defer allocator.free(line);
        try oh.snap(
            @src(),
            \\"\x1b[0m\x1b[30m\x1b[34m\x1b[48:2:247:228:169mbaz\x1b[39m\x1b[30mbux)\x1b[39m\x1b[49m \x1b[32mq\x1b[7muu\x1b[27mx\x1b[39m\x1b[4:5m\x1b[58:5:214m---\x1b[48:5:145m|||\x1b[73m\x1b[35m!!!\x1b[75m\x1b[39m|||\x1b[49m---\x1b[59m\x1b[24m"
            ,
        ).expectEqualFmt(esc_string(line));
    }
    // Drop test
    xprint.newText(&marked);
    {
        _ = try xprint.next();
        _ = try xprint.drop();
        _ = try xprint.next();
        const line = try out_array.toOwnedSlice();
        defer allocator.free(line);
        try oh.snap(
            @src(),
            \\"\x1b[1m\x1b[3m\x1b[38:2:255:0:0maaa\x1b[4m\x1b[58:5:2m111\x1b[23m\x1b[32m333\x1b[39m\x1b[1m\x1b[3m\x1b[38:2:255:0:0m111\x1b[59m\x1b[24maaa\x1b[22m\x1b[23m\x1b[39m\x1b[0m\x1b[4:5m\x1b[58:5:214m---\x1b[48:5:145m|||\x1b[73m\x1b[35m!!!\x1b[75m\x1b[39m|||\x1b[49m---\x1b[59m\x1b[24m"
            ,
        ).expectEqualFmt(esc_string(line));
    }
    // Safe to drop too many lines
    xprint.newText(&marked);
    _ = try xprint.dropN(15);
    try expectEqual(null, xprint.next());
}
