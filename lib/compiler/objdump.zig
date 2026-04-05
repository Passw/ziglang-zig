const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var input_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return Io.File.stdout().writeStreamingAll(io, usage);
            } else {
                fatal("unrecognized argument: {s}", .{arg});
            }
        } else if (input_path == null) {
            input_path = arg;
        } else {
            fatal("unexpected positional: {s}", .{arg});
        }
    }
}

const usage =
    \\Usage: zig objdump [options] file
    \\
    \\Options:
    \\  -h, --help                              Print this help and exit
    \\
;
