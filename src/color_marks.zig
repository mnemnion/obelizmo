//! An enum union representing colors and where they apply.
//!
//! The main type here is `Color`, which is used in a somewhat broad
//! sense.  These come in four varieties, represented as an enum,
//! `StyleClass`: `.foreground`, `.background`, `.underline`, and
//! `.style`.  The style class of a Color may be determined by calling
//! `a_color.style()`.
//!
//! `.background` and `.underline` take ColorValues, which can be the
//! default color, a simple color (the original set), a 256 palette
//! color, or an RGB triple.  These are created with:
//!
//! - `bgDefault`, `bgBasic`, `bg256`, and `bgRgb`
//! - `ulDefault`, `ulBasic`, `ul256`, and `ulRgb`
//!
//! The latter set take, as a first argument, an `UnderlineStyle`:
//! `.single`, `.double`, `.curly`, `.dashed`, and `.dotted`.
//!
//! Foreground colors are created similarly, with an additional
//! function available:
//!
//! - `fgStyle`, `fgDefault`, `fgBasic`, `fg256`, and `fgRgb`
//!
//! To make it easy to define a single Color with all desired attributes,
//! `Color`s in the foreground style may be modified with a list of add-on
//! qualities.  These are built using a fluent interface by calling any
//! number of the following functions:
//!
//! - `bold`, `faint`, `italic`, `blink`, `rapidBlink`, `strikeThrough`,
//!   `overLine`, `superScript`, or `subScript`
//!
//! When `fgStyle` is used, these modifiers will be applied without
//! changing the foreground style.  This also makes it usable as a dummy
//! Color, for any occasion where that may be useful.
//!
//! For implementation reasons, `superScript` will override `subScript` and
//! vice versa, but if both `bold` and `faint` are set, the result will be
//! faint text.
//!
//! Calling these modifier functions on any color where `color.style() !=
//! .foreground` will result in a panic.
//!
//! The `.style` class is a catch-all containing `.invisible`, `.inverse`,
//! and `.reset`.  These are stylings where it doesn't make sense to include
//! a color, and may be created with `invisible`, `inverse`, and `reset`.
//!
//! `.reset` will reset everything.  To make it more specific, you can call
//! the following modifier functions:
//!
//! - `neutral`, `upright`, `steady`, `baseline`, `resetForeground`,
//!   `resetBackground`, `resetUnderline`, and `resetUnderlineColor`
//!
//! The first four being: neither bold nor faint, not italic, not blinking,
//! not super- or subscripted, respectively.  If any of these modifiers are
//! called, only the requested resets will be performed.
//!
//! Calling `printOff` on a reset Color is a no-op.  As with foreground,
//! calling any of the above modifier functions on any other color will panic.
//!
//! Not every terminal will support all of these options, but unrecognized
//! codes are ignored, so the worst that can happen is that a style will not
//! be applied.  One may use `terminfo` or a terminal query to determine what
//! is and isn't supported, but doing so is out of scope for `obelizmo`.
//!

//| TODO: maybe add 'neutral', 'steady', and 'baseline', which
//| have the effect of not-bold-or-faint, not-blinking, and not-italic-
//| or-sub-or-superscript, respectively.

const std = @import("std");
const assert = std.debug.assert;

//| Builder functions

/// Create a foreground for a style-only effect.
/// Example: fgStyle().bold().
pub fn fgStyle() Color {
    return Color{
        .foreground = .{
            .color = null,
        },
    };
}

/// Create the default foreground style.
pub fn fgDefault() Color {
    return Color{
        .foreground = .{
            .color = .default,
        },
    };
}

/// Create a foreground color from the basic palette
pub fn fgBasic(color: BasicColor) Color {
    return Color{
        .foreground = .{
            .color = .{
                .basic = color,
            },
        },
    };
}

/// Create a foreground color from the 256 palette
pub fn fg256(palette: u8) Color {
    return Color{
        .foreground = .{
            .color = .{
                .palette = palette,
            },
        },
    };
}

/// Create an RGB foreground color
pub fn fgRgb(r: u8, g: u8, b: u8) Color {
    return Color{
        .foreground = .{
            .color = .{
                .rgb = .{
                    .r = r,
                    .g = g,
                    .b = b,
                },
            },
        },
    };
}

/// Create the default background style.
pub fn bgDefault() Color {
    return Color{
        .background = .default,
    };
}

/// Create a background color from the basic palette
pub fn bgBasic(color: BasicColor) Color {
    return Color{
        .background = .{
            .basic = color,
        },
    };
}

/// Create a background color from the 256 palette
pub fn bg256(palette: u8) Color {
    return Color{
        .background = .{
            .palette = palette,
        },
    };
}

/// Create an RGB background color
pub fn bgRgb(r: u8, g: u8, b: u8) Color {
    return Color{
        .background = .{
            .rgb = .{
                .r = r,
                .g = g,
                .b = b,
            },
        },
    };
}

/// Create an underline color from the basic palette
pub fn ulBasic(ul: UnderlineStyle, color: BasicColor) Color {
    const shade = ColorValue{
        .basic = color,
    };
    switch (ul) {
        .single => return Color{
            .underline = shade,
        },
        .double => return Color{
            .double_underline = shade,
        },
        .curly => return Color{
            .curly_underline = shade,
        },
        .dotted => return Color{
            .dotted_underline = shade,
        },
        .dashed => return Color{
            .dashed_underline = shade,
        },
    }
}

/// Create an underline color from the 256 palette
pub fn ul256(ul: UnderlineStyle, palette: u8) Color {
    const shade = ColorValue{
        .palette = palette,
    };
    switch (ul) {
        .single => return Color{
            .underline = shade,
        },
        .double => return Color{
            .double_underline = shade,
        },
        .curly => return Color{
            .curly_underline = shade,
        },
        .dotted => return Color{
            .dotted_underline = shade,
        },
        .dashed => return Color{
            .dashed_underline = shade,
        },
    }
}

/// Create an RGB underline color
pub fn ulRgb(ul: UnderlineStyle, r: u8, g: u8, b: u8) Color {
    const shade = ColorValue{
        .rgb = .{
            .r = r,
            .g = g,
            .b = b,
        },
    };
    switch (ul) {
        .single => return Color{
            .underline = shade,
        },
        .double => return Color{
            .double_underline = shade,
        },
        .curly => return Color{
            .curly_underline = shade,
        },
        .dotted => return Color{
            .dotted_underline = shade,
        },
        .dashed => return Color{
            .dashed_underline = shade,
        },
    }
}

/// Create an inverse style.
pub fn inverse() Color {
    return .inverse;
}

/// Create an invisible style.
pub fn invisible() Color {
    return .invisible;
}

/// Create a reset style.
pub fn reset() Color {
    return .reset;
}

pub const ColorAttribute = enum {
    underline,
    inverse,
    invisible,
    reset,
    superscript,
    subscript,
    foreground,
    background,
    double_underline,
    curly_underline,
    dotted_underline,
    dashed_underline,
};

pub const UnderlineStyle = enum {
    single,
    double,
    curly,
    dotted,
    dashed,
};

pub const StyleClass = enum {
    foreground,
    background,
    underline,
    style,
};

pub const BasicColor = enum(u4) {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,

    pub fn value(b: BasicColor) *const [1:0]u8 {
        return switch (b) {
            .black => "0",
            .red => "1",
            .green => "2",
            .yellow => "3",
            .blue => "4",
            .magenta => "5",
            .cyan => "6",
            .white => "7",
        };
    }
};

pub const ColorValue = union(enum(u2)) {
    default,
    basic: BasicColor,
    palette: u8,
    rgb: struct {
        r: u8,
        g: u8,
        b: u8,
    },

    // Note: there appears to be some debate about whether 256 color sequences
    // should be colon or semicolon separated.  RGB mode suffers from this ambiguity
    // but to a lesser degree.
    //
    // I'm going with colons for everything for now, but may need to change this to
    // use semicolons for everything other than underline color, which is a fairly
    // new concept, so we can expect support for the 'correct' sequence to be more-
    // or-less ubiquitous.

    pub fn printOn(c_val: ColorValue, writer: anytype) @TypeOf(writer.*).Error!void {
        switch (c_val) {
            .default => _ = try writer.writeAll("9m"),
            .basic => |basic| {
                _ = try writer.writeAll(basic.value());
                _ = try writer.writeAll("m");
            },
            .palette => |color| {
                try writer.print(":5:{d}m", .{color});
            },
            .rgb => |color| {
                try writer.print(":2::{d}:{d}:{d}m", .{ color.r, color.g, color.b });
            },
        }
    }
};

pub const Resets = packed struct {
    all: bool = true,
    neutral: bool = false,
    upright: bool = false,
    steady: bool = false,
    baseline: bool = false,
    foreground: bool = false,
    background: bool = false,
    underline: bool = false,
    underline_color: bool = false,

    pub fn printOn(r: Resets, writer: anytype) !void {
        if (r.all) {
            try writer.writeAll("\x1b[0m");
            return;
        }
        if (r.neutral) try writer.writeAll("\x1b[22m");
        if (r.upright) try writer.writeAll("\x1b[23m");
        if (r.steady) try writer.writeAll("\x1b[25m");
        if (r.baseline) try writer.writeAll("\x1b[75m");
        if (r.foreground) try writer.writeAll("\x1b[39m");
        if (r.background) try writer.writeAll("\x1b[40m");
        if (r.underline) try writer.writeAll("\x1b[24m");
        if (r.underline_color) try writer.writeAll("\x1b[59m");
    }
};

pub const TextStyles = packed struct {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    blink: bool = false,
    rapid_blink: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
};

pub const ForegroundColor = struct {
    color: ?ColorValue,
    styles: TextStyles = .{},

    pub fn printOn(fg: ForegroundColor, writer: anytype) @TypeOf(writer.*).Error!void {
        if (fg.styles.bold) _ = try writer.writeAll("\x1b[1m");
        if (fg.styles.faint) _ = try writer.writeAll("\x1b[2m");
        if (fg.styles.italic) _ = try writer.writeAll("\x1b[3m");
        if (fg.styles.blink) _ = try writer.writeAll("\x1b[5m");
        if (fg.styles.rapid_blink) _ = try writer.writeAll("\x1b[6m");
        if (fg.styles.strikethrough) _ = try writer.writeAll("\x1b[9m");
        if (fg.styles.overline) _ = try writer.writeAll("\x1b[53m");

        if (fg.color) |color| {
            if (color == .basic or color == .default) {
                _ = try writer.writeAll("\x1b[3");
            } else {
                _ = try writer.writeAll("\x1b[38");
            }
            try color.printOn(writer);
        }
    }

    pub fn printOff(fg: ForegroundColor, writer: anytype) @TypeOf(writer.*).Error!void {
        if (fg.styles.bold or fg.styles.faint) _ = try writer.writeAll("\x1b[22m");
        if (fg.styles.italic) _ = try writer.writeAll("\x1b[23m");
        if (fg.styles.blink or fg.styles.rapid_blink) _ = try writer.writeAll("\x1b[25m");
        if (fg.styles.strikethrough) _ = try writer.writeAll("\x1b[29m");
        if (fg.styles.overline) _ = try writer.writeAll("\x1b[55m");

        if (fg.color) |color| {
            switch (color) {
                .default => {},
                else => _ = try writer.writeAll("\x1b[39m"),
            }
        }
    }

    /// Add bold style to color.
    pub fn bold(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.bold = true;
        return _fg;
    }

    /// Add faint style to color.
    pub fn faint(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.faint = true;
        return _fg;
    }

    /// Add italic style to color.
    pub fn italic(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.italic = true;
        return _fg;
    }

    /// Add blink style to color.
    pub fn blink(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.blink = true;
        return _fg;
    }

    /// Add rapid blink style to color.
    pub fn rapidBlink(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.rapid_blink = true;
        return _fg;
    }

    /// Add strikethrough style to color.
    pub fn strikeThrough(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.strikethrough = true;
        return _fg;
    }

    /// Add overline style to color.
    pub fn overLine(fg: ForegroundColor) ForegroundColor {
        var _fg = fg;
        _fg.styles.overline = true;
        return _fg;
    }
};

pub const Color = union(ColorAttribute) {
    underline: ColorValue,
    inverse,
    invisible,
    reset: Resets,
    superscript: ForegroundColor,
    subscript: ForegroundColor,
    foreground: ForegroundColor,
    background: ColorValue,
    double_underline: ColorValue,
    curly_underline: ColorValue,
    dotted_underline: ColorValue,
    dashed_underline: ColorValue,

    pub fn printOn(color: Color, writer: anytype) @TypeOf(writer.*).Error!void {
        // Write modifier
        switch (color) {
            .underline => _ = try writer.writeAll("\x1b[4m"),
            .inverse => _ = try writer.writeAll("\x1b[7m"),
            .invisible => _ = try writer.writeAll("\x1b[8m"),
            .reset => |r| try r.printOn(writer),
            .superscript => _ = try writer.writeAll("\x1b[73m"),
            .subscript => _ = try writer.writeAll("\x1b[74m"),
            .foreground => {},
            .background => |bg| {
                if (bg == .basic or bg == .default) {
                    _ = try writer.writeAll("\x1b[4");
                } else {
                    _ = try writer.writeAll("\x1b[48");
                }
            },
            .double_underline => _ = try writer.writeAll("\x1b[4:2m"),
            .curly_underline => _ = try writer.writeAll("\x1b[4:3m"),
            .dotted_underline => _ = try writer.writeAll("\x1b[4:4m"),
            .dashed_underline => _ = try writer.writeAll("\x1b[4:5m"),
        }
        // Write color, proper
        switch (color) {
            .inverse, .invisible, .reset => {},
            .background => |bg| try bg.printOn(writer),
            .underline,
            .double_underline,
            .curly_underline,
            .dotted_underline,
            .dashed_underline,
            => |ul| {
                switch (ul) {
                    .default => _ = try writer.writeAll("\x1b[59m"),
                    .basic => |b| {
                        // It doesn't appear that underline colors
                        // support the default palette, so we emulate
                        // as best we can with the bottom of 256.
                        _ = try writer.writeAll("\x1b[58:5:");
                        _ = try writer.writeAll(b.value());
                        _ = try writer.writeAll("m");
                    },
                    .palette, .rgb => {
                        _ = try writer.writeAll("\x1b[58");
                        try ul.printOn(writer);
                    },
                }
            },
            .superscript,
            .subscript,
            .foreground,
            => |fg| {
                try fg.printOn(writer);
            },
        }
    }

    pub fn printOff(color: Color, writer: anytype) @TypeOf(writer.*).Error!void {
        switch (color) {
            .reset => {},
            .inverse => _ = try writer.writeAll("\x1b[27m"),
            .invisible => _ = try writer.writeAll("\x1b[28m"),
            .superscript, .subscript => |base| {
                _ = try writer.writeAll("\x1b[75m");
                try base.printOff(writer);
            },
            .foreground => |fg| try fg.printOff(writer),
            .background => |bg| {
                if (bg != .default) {
                    _ = try writer.writeAll("\x1b[49m");
                }
            },
            .underline,
            .double_underline,
            .curly_underline,
            .dotted_underline,
            .dashed_underline,
            => _ = try writer.writeAll("\x1b[59m\x1b[24m"),
        }
    }

    /// Return the `StyleClass` the `Color` belongs to.
    pub fn style(color: Color) StyleClass {
        switch (color) {
            .underline,
            .double_underline,
            .curly_underline,
            .dotted_underline,
            .dashed_underline,
            => return .underline,
            .inverse,
            .invisible,
            .reset,
            => return .style,
            .foreground, .superscript, .subscript => return .foreground,
            .background => return .background,
        }
    }

    /// Add bold style to color.
    pub fn bold(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.bold();
                return @unionInit(Color, which, styled);
            },
            else => @panic("This Color type cannot take style modifiers"),
        }
    }

    /// Add faint style to color.
    pub fn faint(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.faint();
                return @unionInit(Color, which, styled);
            },
            else => @panic("This Color type cannot take style modifiers"),
        }
    }

    /// Add italic style to color.
    pub fn italic(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.italic();
                return @unionInit(Color, which, styled);
            },
            else => @panic("This Color type cannot take style modifiers"),
        }
    }

    /// Add blink style to color.
    pub fn blink(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.blink();
                return @unionInit(Color, which, styled);
            },
            else => @panic("this Color type cannot take style modifiers"),
        }
    }

    /// Add rapid blink style to color.
    pub fn rapidBlink(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.rapidBlink();
                return @unionInit(Color, which, styled);
            },
            else => @panic("this Color type cannot take style modifiers"),
        }
    }

    /// Make the (foreground-class) color a superscript.
    pub fn superScript(c: Color) Color {
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                return Color{
                    .superscript = fg,
                };
            },
            else => @panic("this color type cannot be made a superscript"),
        }
    }

    /// Make the (foreground-class) color a subscript.
    pub fn subScript(c: Color) Color {
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                return Color{
                    .subscript = fg,
                };
            },
            else => @panic("this color type cannot be made a subscript"),
        }
    }

    /// Add strikethrough style to color.
    pub fn strikeThrough(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.strikeThrough();
                return @unionInit(Color, which, styled);
            },
            else => @panic("this Color type cannot take style modifiers"),
        }
    }

    /// Add overline style to color.
    pub fn overLine(c: Color) Color {
        const which = @tagName(c);
        switch (c) {
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                const styled = fg.overLine();
                return @unionInit(Color, which, styled);
            },
            else => @panic("this Color type cannot take style modifiers"),
        }
    }

    /// Add neutral (not bold or faint) modifier to reset style.
    pub fn neutral(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.neutral = true;
                return Color{ .reset = r };
            },
            else => @panic("neutral may only be set on a reset() color"),
        }
    }

    /// Add upright (not italic) modifier to reset style.
    pub fn upright(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.upright = true;
                return Color{ .reset = r };
            },
            else => @panic("upright may only be set on a reset() color"),
        }
    }

    /// Add steady modifier (not blinking) to reset style.
    pub fn steady(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.steady = true;
                return Color{ .reset = r };
            },
            else => @panic("steady may only be set on a reset() color"),
        }
    }

    /// Add baseline (not super- or sub-script) modifier to reset style.
    pub fn baseline(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.baseline = true;
                return Color{ .reset = r };
            },
            else => @panic("baseline may only be set on a reset() color"),
        }
    }

    /// Modify reset style to reset background.
    pub fn resetBackground(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.background = true;
                return Color{ .reset = r };
            },
            else => @panic("reset background may only be set on a reset() color"),
        }
    }

    /// Modify reset style to reset foreground.
    pub fn resetForeground(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.foreground = true;
                return Color{ .reset = r };
            },
            else => @panic("reset foreground may only be set on a reset() color"),
        }
    }

    /// Modify reset style to reset underline.
    pub fn resetUnderline(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.underline = true;
                return Color{ .reset = r };
            },
            else => @panic("reset underline may only be set on a reset() color"),
        }
    }

    /// Modify reset style to reset underline color.
    pub fn resetUnderlineColor(c: Color) Color {
        switch (c) {
            .reset => |r| {
                var new_r = r;
                new_r.all = false;
                new_r.underline_color = true;
                return Color{ .reset = r };
            },
            else => @panic("reset underline color may only be set on a reset() color"),
        }
    }
};
