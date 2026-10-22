pub fn identify(r: *Io.Reader) error{ReadFailed}!bool {
    const magic = r.peek(std.elf.MAGIC.len) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => |e| return e,
    };
    return std.mem.eql(u8, magic, std.elf.MAGIC);
}

pub fn dump(d: *const Objdump) Objdump.Error!void {
    return d.fail("TODO: dump ELF file", .{});
}

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Objdump = @import("../Objdump.zig");
