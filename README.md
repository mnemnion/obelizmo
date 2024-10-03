# Obeli⚡️mo: A String Marking Library

This library provides a flexible system for marking up text, a practice referred to in ancient days as [Obelism](https://en.wikipedia.org/wiki/Obelism).  A relic of this use is the [obelus](https://en.wikipedia.org/wiki/Obelus), which you know is an oddball word, since in English, it means `÷` or `†`, depending.

The goal of `obelizmo` is to provide a performant and output-agnostic way to mark up a string, keeping the metadata and the text separate.  A claim like "output-agnostic" always has its limits: `obelizmo` in its present state is a capable obelist of ANSI escape sequences and HTML, and the mechanism provided is, perhaps, general enough to accomodate other formats as well.

## Status

This library is entirely usable at present for its main focus, which is terminal printing.  I'm reasonably happy with the structure of the marked strings, and the collection of methods for marking them is acceptably featureful.  Printing with ANSI/SGR is fully implemented, with proper handling of nested regions and a color builder.  Printing in HTML is... possible, and might be good enough for your purposes.  I have a long-term goal to come up with a really nice solution there, but it wasn't the primary application of interest.

## Marking Strings

To use the library, define an `enum` of all the categories of markup you intend to use.  A simple example:

```zig
const Colors = enum(u32) {
    blue,
    red,
    yellow,
    green,
    teal, // However many you would like
};
```

This enum can be non-exhaustive, and it is valid to assign any number you like to the enums (although using the default order is optimal).  The enum may be smaller or larger than `u32`, but smaller will not save space because of alignment, and larger will bloat the size of marks.

The enum is provided to `obelizmo.MarkedString(Enum_T)`, which returns a `MarkedString` specialized to that enum.  This is initialized with the string, and an allocator, like so:

```zig
const ColorMarker = obelizmo.MarkedString(Colors);

const a_string_marker = ColorMarker.init(allocator, a_string);
defer a_string_marker.deinit();

// Or you can reserve capacity for some number of marks.
const another_string_marker = try ColorMarker.initCapacity(allocator, a_string, 8);
defer another_string_marker.deinit();
```

Now you're ready to provide some marks.

## Marking up a MarkedString

A collection of member functions for marking up strings is provided.  Some of these have return values, which you're free to ignore.  Invalid inputs will return errors, as will failure to allocate.

Marks may be provided in any order. They're stored on a [priority queue](https://ziglang.org/documentation/master/std/#std.priority_queue.PriorityQueue), which has predicable and good algorithmic complexity for this purpose.

Usage note: be aware that marks can overlap each other, and this may give undesired results, depending on how you choose to print the marked string.  No attempt is made to correct for this condition, or compensate for it.  Among other reasons, this is because there are real uses for which overlapping marks are correct.  The terminal printer handles this with aplomb, but if you wish to produce valid HTML, you'll need the marks to properly nest.

Also worth knowing: if you mark a single region repeatedly, the lower-valued enum will print first on entry, and last on exit.

### Direct Marking

The simplest option is to specify either a slice, or an offset and length, to mark.

```zig
try string_marker.markSlice(.red, a, b) catch |e| {
    switch(err) {
        error.OutOfMemory => |err| return err,
        error.InvalidRegion => @panic(".markSlice provided with invalid data"),
    }
};

try string_marker.markFrom(.blue, a, 7); // Same error set as markSlice
```

### Find and Mark

Another way to mark the string is using the find functions, which work like their equivalents in [std.mem](https://ziglang.org/documentation/master/std/#std.mem.indexOf).  These return the index if a mark was applied, or `null` otherwise, and can only fail to allocate.

```zig
const first_err: usize = try string_marker.findAndMark(.red, "ERROR:").?;

_ = try string_marker.findAndMarkPos(.red, "ERROR:", first_err + 7);

_ = try string_marker.findAndMarkLast(.yellow, "line");
```

### Match and Mark

The last way to apply marks is by using an [mvzr Regex](https://github.com/mnemnion/mvzr), or several.  These functions are actually type-generic, so anything which precisely matches the interface and field names used in `mvzr` would suffice.  But so far as I'm aware, that list only includes `mvzr` at the present time.  The main reason for this is that `mvzr` statically allocates Regexen, so the structs themselves are comptime-generic by size.

```zig
const number_regex = mvzr.Regex.compile("\\d+").?;
const index: ?usize = try string_marker.matchAndMark(.teal, number_regex);
if (index) |i| {
   _ = try string_marker.matchAndMarkPos(.yellow, number_regex, index.? + 10);
}
const fizz_regex = mvzr.Regex.compile("([Ff]izz([Bb]uzz)?)|[Bbuzz])").?;
const did_match: bool = try string_marker.matchAndMarkAll(.teal, fizz_regex);
if (!did_match) {
    std.debug.print("definitely not fizzbuzz\n", .{});
}
```

That's it for marking methods.  If you have some complex structure, like an abstract or concrete syntax tree, you should find it easy to mark up the string using the direct methods, since one of `[start, end]` or `[offset, length]` is generally used to store the span in those structures.  As a reminder, the order of marking doesn't matter, any order will result in the same printed value and will take more-or-less as long to build as any other.  So any convenient approach to iterating such a tree will suit the purpose.

### Printing

Once your `MarkedString` is marked, you'll probably want to print it to something, or potentially several somethings.  `obelizmo` provides for a couple of approaches to this.

The simpler printer uses `marked_string.writeAsTree(writer, markups)`, where the second parameter is a `MarkupStringArray`. This is an [EnumArray](https://ziglang.org/documentation/master/std/#std.enums.EnumArray) where the value type is `[2][]const u8`, for the beginning and end of the region marked with a given enum.  Suitably loaded with the right tags, and given that the `MarkedString` has the right shape, this can produce acceptable HTML.

HTML body text needs to be escaped, for which you can use `HTMLEncodedWriter`, wrapping the underlying Writer of your choice.

### Printing A MarkedString to the Terminal

This use case was the real motivation for this project, and the fully-supported one, so we'll focus there.

The marks are just marks: a struct holding the provided enum, as well as the boundaries of the text region in `[offset, length]` form.  To print to the terminal, you'll need to create `Color`s, and a `MarkupColorArray`, this is another `EnumArray` where the value is `Color`.

Next, create an `XtermLinePrinter` specialized to the Writer for the terminal.  Initialize with `init` and call `next`:

```zig
const xprint = XtermPrinter.init(&marked_string, markup_array, writer);
defer xprint.deinit();

while (try xprint.next()) |more| {
    // `more` is true until the final line
    // Newlines are not printed, for terminal raw-mode reasons,
    // So this is where you place the cursor where you want it.
    // When complete, next() will return null.
}
```
Foreground, background, and underline colors, are kept on separate stacks, and will restart automatically at the end of any given marked region.  You can keep the `xprint` around for later, and provide a fresh `MarkedString` with `xprint.newText(&marked_string)`.

That's Obeli⚡️mo.  Mark a string, print it.
