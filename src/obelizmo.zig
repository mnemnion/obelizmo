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

        /// Find `needle` in string and mark with `mark`.  Returns the
        /// index if the needle was found and marked, otherwise `null`.
        pub fn findAndMark(
            marker: *SMark,
            mark: Kind,
            needle: []const u8,
        ) !?usize {
            const idx = std.mem.indexOf(u8, marker.string, needle);
            if (idx) |i| {
                try marker.markFrom(mark, i, needle.len);
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
        ) !?usize {
            const idx = std.mem.indexOfPos(u8, marker.string, pos, needle);
            if (idx) |i| {
                try marker.markFrom(mark, i, needle.len);
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
        ) !bool {
            const idx = std.mem.lastIndexOf(u8, marker.string, needle);
            if (idx) |i| {
                try marker.markFrom(mark, i, needle.len);
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
        ) !?usize {
            const maybe_match = regex.match(marker.string);
            if (maybe_match) |match| {
                try marker.markSlice(mark, match.start, match.end);
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
        ) !?usize {
            const maybe_match = regex.matchPos(pos, marker.string);
            if (maybe_match) |match| {
                try marker.markSlice(mark, match.start, match.end);
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
        ) !bool {
            var matcher = regex.iterator(marker.string);
            var a_match = false;
            while (matcher.next()) |match| {
                a_match = true;
                try marker.markSlice(mark, match.start, match.end);
            }
            return a_match;
        }

        //| Writing

        pub const StreamOption = enum {
            skip_on_zero_width,
            include_zero_width,
        };

        pub fn writeAsStream(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupArray,
        ) !void {
            return marker.writeAsStreamWithOptions(
                writer,
                markups,
                .skip_on_zero_width,
            );
        }

        fn cloneQueue(queue: MarkQueue) !MarkQueue {
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

        /// Write out the marked string as a stream: this is designed to
        /// work with protocols like ANSI terminal sequences, where the
        /// style signaling is in-band, and has to be repeated in order
        /// for nested regions to print correctly.  If emitting a tree-
        /// shaped markup syntax, such as XML or HTML, use `writeAsTree`.
        pub fn writeAsStreamWithOptions(
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
            var in_q = try cloneQueue(marker.queue);
            defer in_q.deinit();
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

        /// Write the `MarkedString` as a tree.  This is more compatible
        /// with XML/HTML style markup, where each marked region is a
        /// span or such.  Every mark is begun and ended once, with no
        /// logic to restart an outer span once an inner span is closed,
        /// as is necessary to get good results printing to a terminal.
        /// For that purpose, use `writeAsStream`.
        pub fn writeAsTree(
            marker: *const SMark,
            writer: anytype,
            markups: MarkupArray,
        ) !void {
            // We use a second queue with a different comparison function, such
            // that the front of the queue is always the next-outermost Mark.
            const allocator = marker.queue.allocator;
            const string = marker.string;
            var in_q = try cloneQueue(marker.queue);
            defer in_q.deinit();
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
                    // Write our bookend.
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
            }
            // Write the rest of the string, if any
            try writer.writeAll(string[cursor..]);

            return;
        }

        /// Define a type for a given generic Writer, which is
        /// initialized with `WriteIterator.init(marker: *MarkedString,
        /// writer: WriterType, markups: MarkupArray, limit: usize)`.
        /// Repeated calls to `iterator.writeStream()`, or alternately,
        /// `iterator.writeTree()`, will write `limit` bytes or less,
        /// returning the amount written, and return `null` when there
        /// is no more string left to write.  This iterator allocates
        /// memory internally, use `write_iterator.deinit()` to free
        /// after use.
        ///
        /// ## Usage Note
        ///
        /// The limit provided must be larger than any of the decoraters
        /// in the `MarkupArray`, or the write will be unable to process,
        /// because we never perform a partial write of those strings. If
        /// this happens, the iterator will return 0, having written no
        /// bytes.  The best thing is to simply not put yourself in that
        /// situation, but if, for instance, all marks are dynamic, you
        /// can at least detect the condition that way, and decide what
        /// to do other than infinitely loop.
        pub fn WriteIterator(WriterType: type) type {
            return struct {
                marker: *const SMark,
                writer: WriterType,
                markups: MarkupArray,
                in_q: MarkQueue,
                out_q: SweepQueue,
                limit: usize,
                cursor: usize = 0,
                print_left: bool = false,
                options: StreamOption,

                const StreamWrite = @This();

                pub fn initOptions(
                    marker: *const SMark,
                    writer: WriterType,
                    markups: MarkupArray,
                    limit: usize,
                    options: StreamOption,
                ) !StreamWrite {
                    return StreamWrite{
                        .marker = marker,
                        .writer = writer,
                        .in_q = try cloneQueue(marker.queue),
                        .out_q = SweepQueue.init(marker.queue.allocator, {}),
                        .markups = markups,
                        .limit = limit,
                        .options = options,
                    };
                }

                pub fn init(
                    marker: *const SMark,
                    writer: WriterType,
                    markups: MarkupArray,
                    limit: usize,
                ) !StreamWrite {
                    return StreamWrite.initOptions(
                        marker,
                        writer,
                        markups,
                        limit,
                        .skip_on_zero_width,
                    );
                }

                /// Free the iterator's allocated memory.
                pub fn deinit(iter: *StreamWrite) void {
                    iter.in_q.deinit();
                    iter.out_q.deinit();
                }

                /// XXX Debug
                fn printMark(string: []const u8, mark: Mark, nl: []const u8) void {
                    std.debug.print("mark {s}{s}", .{ string[mark.offset .. mark.offset + mark.len], nl });
                }

                pub fn writeStream(iter: *StreamWrite) !?usize {
                    if (iter.cursor >= iter.marker.string.len) return null;
                    const string = iter.marker.string;
                    var in_q = &iter.in_q;
                    const markups = &iter.markups;
                    var out_q = &iter.out_q;
                    var writer = &iter.writer;
                    // We always pull a fresh Mark. Even if it takes
                    // several tail calls to clear the out marks, or to
                    // write the final bit of the tail, this is safe,
                    // we just put it back when we can't write it.
                    var this_mark = in_q.removeOrNull();
                    const no_zero = iter.options == .skip_on_zero_width;
                    var count: usize = 0;
                    // Check if we have a left to print:
                    if (iter.print_left) {
                        iter.print_left = false;
                        const left_mark = out_q.peek().?;
                        const left = markups.get(left_mark.kind)[LEFT];
                        // if (no_zero and left_mark.final() == iter.cursor) {
                        //     _ = out_q.remove();
                        // }
                        if (count + left.len <= iter.limit) {
                            count += try writer.write(left);
                        } else {
                            return 0;
                        }
                    }
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
                        // Write up to our next obelus.
                        if (iter.cursor < next_idx) {
                            if (count + (next_idx - iter.cursor) <= iter.limit) {
                                count += try writer.write(string[iter.cursor..next_idx]);
                                assert(count <= iter.limit);
                            } else {
                                const this_limit = iter.cursor + (iter.limit - count);
                                const frag = string[iter.cursor..this_limit];
                                count += try writer.write(frag);
                                assert(count == iter.limit);
                                iter.cursor = this_limit;
                                // Replace the unused mark on the queue.
                                try in_q.add(mark);
                                return count;
                            }
                            iter.cursor = next_idx;
                        } else {
                            // Invalid for the index to be behind the cursor.
                            assert(iter.cursor == next_idx);
                        }
                        if (from_this_mark) {
                            // First we need to close the out mark, if there is one.
                            if (maybe_next) |next| {
                                if (next.final() >= mark.offset) {
                                    if (!no_zero or (no_zero and next.offset < iter.cursor)) {
                                        const right = markups.get(next.kind)[RIGHT];
                                        if (count + right.len > iter.limit) {
                                            try in_q.add(mark);
                                            return count;
                                        } else {
                                            count += try writer.write(right);
                                            assert(count <= iter.limit);
                                        }
                                    }
                                }
                            }
                            // Write our bookend.
                            // We might have a zero-width to skip though:
                            if (no_zero) {
                                const maybe_next_next = in_q.peek();
                                if (maybe_next_next) |next| {
                                    // No need to open a sequence if we're just
                                    // going to replace it next:
                                    if (next.offset == mark.offset) {
                                        // Push the mark, but don't write it.
                                        try out_q.add(mark);
                                        this_mark = in_q.remove();
                                        continue :marking;
                                    }
                                }
                            }
                            const left = markups.get(mark.kind)[LEFT];
                            if (count + left.len <= iter.limit) {
                                count += try writer.write(left);
                                assert(count <= iter.limit);
                            } else {
                                // Replace the mark for next time.
                                try in_q.add(mark);
                                return count;
                            }
                            // Enplace on the out queue.
                            try out_q.add(mark);
                            // Pull the next mark.
                            this_mark = in_q.removeOrNull();
                            continue :marking;
                        } else {
                            // This mark isn't up yet, write the end off the queue.
                            // We know it exists:
                            const end_mark = out_q.peek().?;
                            const right = markups.get(end_mark.kind)[RIGHT];
                            if (count + right.len <= iter.limit) {
                                count += try writer.write(right);
                                assert(count <= iter.limit);
                                _ = out_q.remove();
                            } else {
                                // Set it up for next time
                                try in_q.add(mark);
                                return count;
                            }
                            // Now stream the left mark from the next on-queue, if any.
                            const maybe_left_mark = out_q.peek();
                            if (maybe_left_mark) |left_mark| {
                                if (no_zero and left_mark.final() == iter.cursor) {
                                    _ = out_q.remove();
                                } else {
                                    const left = markups.get(left_mark.kind)[LEFT];
                                    if (count + left.len <= iter.limit) {
                                        count += try writer.write(left);
                                        assert(count <= iter.limit);
                                    } else {
                                        // Print it next time.
                                        iter.print_left = true;
                                        try in_q.add(mark);
                                        return count;
                                    }
                                }
                            }
                            continue :marking;
                        }
                    } // end :marking
                    // There may still be marks on the out queue to drain.
                    while (out_q.removeOrNull()) |out_mark| {
                        const slice_end = out_mark.final();
                        if (count + (slice_end - iter.cursor) <= iter.limit) {
                            count += try writer.write(string[iter.cursor..slice_end]);
                            assert(count <= iter.limit);
                        } else {
                            // Put it back.
                            try out_q.add(out_mark);
                            return count;
                        }
                        iter.cursor = slice_end;
                        const right = markups.get(out_mark.kind)[RIGHT];
                        if (count + right.len <= iter.limit) {
                            count += try writer.write(right);
                            assert(count <= iter.limit);
                        } else {
                            // Put it back...
                            try out_q.add(out_mark);
                            return count;
                        }
                        const maybe_left_mark = out_q.peek();
                        if (maybe_left_mark) |left_mark| {
                            const left = markups.get(left_mark.kind)[LEFT];
                            if (count + left.len <= iter.limit) {
                                count += try writer.write(left);
                                assert(count <= iter.limit);
                            } else {
                                // Next time.
                                iter.print_left = true;
                                return count;
                            }
                        }
                    }
                    // Write the rest of the string, if any
                    const the_rest = string[iter.cursor..];
                    if (count + the_rest.len <= iter.limit) {
                        count += try writer.write(the_rest);
                        assert(count <= iter.limit);
                        iter.cursor = string.len;
                    } else {
                        const enough = iter.cursor + (iter.limit - count);
                        count += try writer.write(string[iter.cursor..enough]);
                        iter.cursor = enough;
                        assert(count == iter.limit);
                        return count;
                    }

                    return count;
                }

                pub fn writeTree(iter: *StreamWrite) !?usize {
                    const string = iter.marker.string;
                    var in_q = &iter.in_q;
                    var out_q = &iter.out_q;
                    var writer = &iter.writer;
                    const markups = iter.markups;
                    // TODO left marks, probably?
                    var this_mark = in_q.removeOrNull();
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
                        if (iter.cursor < next_idx) {
                            if (count + (next_idx - iter.cursor) <= iter.limit) {
                                count += try writer.write(string[iter.cursor..next_idx]);
                                assert(count <= iter.limit);
                            } else {
                                const this_limit = iter.cursor + (iter.limit - count);
                                const frag = string[iter.cursor..this_limit];
                                count += try writer.write(frag);
                                assert(count == iter.limit);
                                iter.cursor = this_limit;
                                // Replace the unused mark on the queue.
                                try in_q.add(mark);
                                return count;
                            }
                            iter.cursor = next_idx;
                        } else {
                            // Invalid for the index to be behind the cursor.
                            assert(iter.cursor == next_idx);
                        }
                        if (from_this_mark) {
                            // Write our bookend.
                            const left = markups.get(mark.kind)[LEFT];
                            if (count + left.len <= iter.limit) {
                                count += try writer.write(left);
                                assert(count <= iter.limit);
                            } else {
                                // Replace the mark for next time.
                                try in_q.add(mark);
                                return count;
                            }
                            // Enplace on the out queue.
                            try out_q.add(mark);
                            // Pull the next mark.
                            this_mark = in_q.removeOrNull();
                            continue :marking;
                        } else {
                            // This mark isn't up yet, write the end off the queue.
                            // We know it exists:
                            const end_mark = out_q.peek().?;
                            const right = markups.get(end_mark.kind)[RIGHT];
                            if (count + right.len <= iter.limit) {
                                count += try writer.write(right);
                                assert(count <= iter.limit);
                                _ = out_q.remove();
                            } else {
                                // Set it up for next time
                                try in_q.add(mark);
                                return count;
                            }
                            // Now stream the left mark from the next on-queue, if any.
                            continue :marking;
                        }
                    } // end :marking
                    // There may still be marks on the out queue to drain
                    while (out_q.removeOrNull()) |out_mark| {
                        const slice_end = out_mark.final();
                        if (count + (slice_end - iter.cursor) <= iter.limit) {
                            count += try writer.write(string[iter.cursor..slice_end]);
                            assert(count <= iter.limit);
                        } else {
                            // Put it back.
                            try out_q.add(out_mark);
                            return count;
                        }
                        iter.cursor = slice_end;
                        const right = markups.get(out_mark.kind)[RIGHT];
                        if (count + right.len <= iter.limit) {
                            count += try writer.write(right);
                            assert(count <= iter.limit);
                        } else {
                            // Put it back...
                            try out_q.add(out_mark);
                            return count;
                        }
                    }
                    // Write the rest of the string, if any
                    const the_rest = string[iter.cursor..];
                    if (count + the_rest.len <= iter.limit) {
                        count += try writer.write(the_rest);
                        assert(count <= iter.limit);
                        iter.cursor = string.len;
                    } else {
                        const enough = iter.cursor + (iter.limit - count);
                        count += try writer.write(string[iter.cursor..enough]);
                        iter.cursor = enough;
                        assert(count == iter.limit);
                        return count;
                    }

                    return count;
                }
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
    var stream_writer = out_array.writer();
    try color_marker.writeAsStream(&stream_writer, color_markup);
    const stream_string = try out_array.toOwnedSlice();
    defer allocator.free(stream_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>red</r> <b>blue</b><t> </t><g>green</g> <y>yellow</y>"
        ,
    ).expectEqual(stream_string);
    try color_marker.writeAsTree(&stream_writer, color_markup);
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
    const writer = out_array.writer();
    try color_marker.writeAsStream(writer, color_markup);
    const stream_string = try out_array.toOwnedSlice();
    defer allocator.free(stream_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>func</r> <b>10</b> <r>f</r><y>u</y><r>nky</r> <b>456</b>"
        ,
    ).expectEqual(stream_string);
    try color_marker.writeAsTree(writer, color_markup);
    const tree_string = try out_array.toOwnedSlice();
    defer allocator.free(tree_string);
    try oh.snap(
        @src(),
        \\[]u8
        \\  "<r>func</r> <b>10</b> <r>f<y>u</y>nky</r> <b>456</b>"
        ,
    ).expectEqual(tree_string);
}

test "Write Iterator" {
    const mark_string = "abc 123 def ghi 34 \n" ** 30;
    const oh = OhSnap{};
    _ = oh; // autofix
    const allocator = testing.allocator;
    var color_marker = try ColorMarker.initCapacity(allocator, mark_string, 4);
    defer color_marker.deinit();
    const num_regex = Regex.compile("\\d+").?;
    _ = try color_marker.matchAndMarkAll(.red, num_regex);
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    const writer = out_array.writer();
    try color_marker.writeAsStream(writer, color_markup);
    const reference_string = try out_array.toOwnedSlice();
    defer allocator.free(reference_string);
    const WriteIterator = ColorMarker.WriteIterator(@TypeOf(writer));
    {
        var limit: usize = 7;
        while (limit < reference_string.len) : (limit += 5) {
            var iter = try WriteIterator.init(
                &color_marker,
                writer,
                color_markup,
                limit,
            );
            defer iter.deinit();
            while (try iter.writeStream()) |c| {
                if (c == 0) try expect(false);
            }
            const test_string = try out_array.toOwnedSlice();
            defer allocator.free(test_string);
            try expectEqualStrings(reference_string, test_string);
        }
    }
    const outer_regex = Regex.compile("123 def").?;
    _ = try color_marker.matchAndMarkAll(.blue, outer_regex);
    try color_marker.writeAsStream(writer, color_markup);
    const out_ref_string = try out_array.toOwnedSlice();
    defer allocator.free(out_ref_string);
    {
        var limit: usize = 7;
        while (limit < reference_string.len) : (limit += 5) {
            var iter = try WriteIterator.init(
                &color_marker,
                writer,
                color_markup,
                limit,
            );
            defer iter.deinit();
            while (try iter.writeStream()) |c| {
                if (c == 0) try expect(false);
            }
            const test_string = try out_array.toOwnedSlice();
            defer allocator.free(test_string);
            try expectEqualStrings(out_ref_string, test_string);
        }
    }
}
