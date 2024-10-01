//! An enum union representing colors and where they apply.
//!
//! This is fairly terminal specific.

const std = @import("std");

pub const ColorAttribute = enum {
    underline,
    inverse,
    invisible,
    strikethrough,
    overline,
    superscript,
    subscript,
    foreground,
    background,
    double_underline,
    curly_underline,
    dotted_underline,
    dashed_underline,
};

pub const StyleClass = enum {
    foreground,
    background,
    underline,
    style,
};

pub const ColorValue = union(enum(u1)) {
    palette: u8,
    rgb = struct {
        r: u8,
        g: u8,
        b: u8,
    },

    pub fn printOn(c_val: ColorValue, writer: anytype) @TypeOf(writer.*).Error!void {
        switch (c_val) {
            .palette => |color| {
                try writer.print(":5:{d}m", .{color});
            },
            .rgb => |color| {
                try writer.print(":2::{d}:{d}:{d}m", .{ color.r, color.g, color.b });
            },
        }
    }
};

pub const ForegroundColor = struct {
    color: ?ColorValue,
    styles: packed struct {
        bold: bool = false,
        faint: bool = false,
        italic: bool = false,
        blink: bool = false,
        rapid_blink: bool = false,
    },

    pub fn printOn(fg: ForegroundColor, writer: anytype) @TypeOf(writer.*).Error!void {
        if (fg.styles.bold) _ = try writer.writeAll("\x1b[1m");
        if (fg.styles.faint) _ = try writer.writeAll("\x1b[2m");
        if (fg.styles.italic) _ = try writer.writeAll("\x1b[3m");
        if (fg.styles.blink) _ = try writer.writeAll("\x1b[5m");
        if (fg.styles.rapid_blink) _ = try writer.writeAll("\x1b[6m");
        if (fg.color) |color| {
            _ = try writer.writeAll("\x1b[38:");
            try color.printOn(writer);
        }
    }

    pub fn printOff(fg: ForegroundColor, writer: anytype) @TypeOf(writer.*).Error!void {
        if (fg.styles.bold or fg.styles.faint) _ = try writer.writeAll("\x1b[22m");
        if (fg.styles.italic) _ = try writer.writeAll("\x1b[23m");
        if (fg.styles.blink or fg.style.rapid_blink) _ = try writer.writeAll("\x1b[25m");
        if (fg.color) |_| {
            _ = try writer.writeAll("\x1b[39m");
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
};

pub const Color = union(ColorAttribute) {
    underline: ColorValue,
    inverse,
    invisible,
    strikethrough,
    overline,
    superscript: ForegroundColor,
    subscript: ForegroundColor,
    foreground: ForegroundColor,
    background: ColorValue,
    double_underline: ColorValue,
    curly_underline: ColorValue,
    dotted_underline: ColorValue,
    dashed_underline: ColorValue,

    pub fn printOn(color: Color, writer: anytype) @TypeOf(writer.*).Error!usize {
        // Write modifier
        switch (color) {
            .underline => _ = try writer.writeAll("\x1b[4m\x1b[58:"),
            .inverse => _ = try writer.writeAll("\x1b[7m"),
            .invisible => _ = try writer.writeAll("\x1b[8m"),
            .strikethrough => _ = try writer.writeAll("\x1b[9m"),
            .overline => _ = try writer.writeAll("\x1b[53m"),
            .superscript => _ = try writer.writeAll("\x1b[73m"),
            .subscript => _ = try writer.writeAll("\x1b[74m"),
            .foreground => _ = {},
            .background => _ = try writer.writeAll("\x1b[48:"),
            .double_underline => _ = try writer.writeAll("\x1b[4:2:58:"),
            .curly_underline => _ = try writer.writeAll("\x1b[4:3:58:"),
            .dotted_underline => _ = try writer.writeAll("\x1b[4:4:58:"),
            .dashed_underline => _ = try writer.writeAll("\x1b[4:5:58:"),
        }
        // Write color, proper
        switch (color) {
            .strikethrough, .inverse, .invisible, .overline => {},
            .underline,
            .background,
            .double_underline,
            .curly_underline,
            .dotted_underline,
            .dashed_underline,
            => |c| try c.printOn(writer),
            .foreground,
            .superscript,
            .subscript,
            => |fg| {
                try fg.printOn(writer);
            },
        }
    }

    pub fn printOff(color: Color, writer: anytype) @TypeOf(writer.*).Error!void {
        switch (color) {
            .inverse => _ = try writer.writeAll("\x1b[27m"),
            .invisible => _ = try writer.writeAll("\x1b[28m"),
            .strikethrough => _ = try writer.writeAll("\x1b[29m"),
            .overline => _ = try writer.writeAll("\x1b[55m"),
            .superscript, .subscript => |baseline| {
                _ = try writer.writeAll("\x1b[75m");
                try baseline.printOff(writer);
            },
            .foreground => |fg| try fg.printOff(writer),
            .background => _ = try writer.writeAll("\x1b[49m"),
            .underline,
            .double_underline,
            .curly_underline,
            .dotted_underline,
            .dashed_underline,
            => _ = try writer.writeAll("\x1b[59m\x1b[24m"),
        }
    }

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
            .strikethrough,
            .overline,
            => return .style,
            .foreground, .superscript, .subscript => return .foreground,
            .background => return .background,
        }
    }
};
