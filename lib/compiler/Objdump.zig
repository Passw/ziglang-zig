const Objdump = @This();

const std = @import("std");
const assert = std.debug.assert;
const fatal = std.process.fatal;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const archive = @import("Objdump/archive.zig");
const elf = @import("Objdump/elf.zig");
const macho = @import("Objdump/macho.zig");
const wasm = @import("Objdump/wasm.zig");
const coff = @import("Objdump/coff.zig");

gpa: Allocator,
opts: Options,
w: *Io.Writer,

input_name: []const u8,

seek_base: u64,
raw_file_reader: *Io.File.Reader,
limited_reader: ?*Io.Reader.Limited,

pub fn reader(d: *const Objdump) *Io.Reader {
    if (d.limited_reader) |lr| {
        return &lr.interface;
    } else {
        return &d.raw_file_reader.interface;
    }
}

pub fn logicalPos(d: *const Objdump) u64 {
    if (d.limited_reader) |lr| {
        return d.raw_file_reader.logicalPos() - lr.interface.bufferedLen() - d.seek_base;
    } else {
        assert(d.seek_base == 0);
        return d.raw_file_reader.logicalPos();
    }
}

pub fn atEnd(d: *const Objdump) bool {
    if (d.limited_reader) |lr| {
        if (lr.interface.bufferedLen() != 0) return false;
        if (lr.remaining == .nothing) return true;
    } else {
        assert(d.seek_base == 0);
    }
    return d.raw_file_reader.atEnd();
}

pub fn seekTo(d: *const Objdump, new_pos: u64) (Io.Cancelable || Io.UnexpectedError || error{ReadFailed})!void {
    if (d.limited_reader) |lr| {
        const old_pos = d.logicalPos();
        if (new_pos >= old_pos and new_pos <= old_pos + lr.interface.bufferedLen()) {
            lr.interface.toss(@intCast(new_pos - old_pos));
            return;
        }
        if (lr.remaining.toInt64()) |old_remaining| {
            const total_available = old_pos + lr.interface.bufferedLen() + old_remaining;
            lr.remaining = .limited64(total_available -| new_pos);
        }
        lr.interface.tossBuffered();
    } else {
        assert(d.seek_base == 0);
    }
    d.raw_file_reader.seekTo(d.seek_base + new_pos) catch |err| switch (err) {
        error.Unseekable,
        error.AccessDenied,
        => |e| fatal("failed to seek input file: {t}", .{e}),

        error.EndOfStream => {}, // swallow and let the caller re-trigger

        else => |e| return e,
    };
}

pub const Error = Allocator.Error ||
    error{ReadFailed} ||
    Io.Writer.Error ||
    Io.Cancelable ||
    Io.UnexpectedError ||
    error{AlreadyReported};

pub const Options = struct {
    exports: bool,
    exports_sort: bool,
    file_headers: bool,
    imports: bool,
    archive_symbols: bool,
    archive_member_headers: bool,
    archive_member_filters: []const []const u8,
    elements: std.enums.EnumArray(Element, bool),
    redact: std.enums.EnumArray(FieldKind, bool),
    relocs: bool,
    section_filters: []const []const u8,
    section_headers: bool,
    symbol_filters: []const []const u8,
    strings: bool,
    symbols: bool,
    tls: bool,
};

pub fn element(self: *const Objdump, e: Element) bool {
    return self.opts.elements.get(e);
}

pub fn redacted(self: *const Objdump, opt_kind: ?FieldKind) bool {
    const kind = opt_kind orelse return false;
    return self.opts.redact.get(kind);
}

pub fn fmtAddress(d: *const Objdump, addr: u64, width: FormatAddress.Width) FormatAddress {
    return .{
        .addr = if (d.redacted(.va)) null else addr,
        .width = width,
    };
}
pub const FormatAddress = struct {
    addr: ?u64,
    width: Width,
    pub const Width = enum { no_pad, pad_8, pad_16 };
    pub fn format(ctx: FormatAddress, w: *Io.Writer) Io.Writer.Error!void {
        if (ctx.addr) |addr| {
            switch (ctx.width) {
                .no_pad => try w.print("0x{X}", .{addr}),
                .pad_8 => try w.print("0x{X:0>8}", .{addr}),
                .pad_16 => try w.print("0x{X:0>16}", .{addr}),
            }
        } else {
            switch (ctx.width) {
                .no_pad, .pad_8 => try w.writeAll("xxxxxxxxxx"),
                .pad_16 => try w.writeAll("xxxxxxxxxxxxxxxxxx"),
            }
        }
    }
};

pub fn fail(
    d: *const Objdump,
    comptime fmt: []const u8,
    args: anytype,
) (Io.Writer.Error || error{AlreadyReported}) {
    try d.w.flush();
    std.log.err("failed to parse {s}: " ++ fmt, .{d.input_name} ++ args);
    try d.w.writeByte('\n'); // trailing newline for this input
    return error.AlreadyReported;
}

pub fn warn(
    d: *const Objdump,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    try d.w.flush();
    std.log.warn(fmt, args);
}

pub const FieldKind = enum {
    va,
    rva,
    ord,
    size,
};

const Element = enum {
    @"file-type",
    @"header-name",
    @"input-path",
    @"member-path",
    newlines,
    @"table-header",
};

pub fn main(init: std.process.Init) (Io.UnexpectedError || Io.Cancelable || Allocator.Error)!u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var input_paths: std.ArrayList([]const u8) = .empty;

    var exports: bool = false;
    var exports_sort: bool = false;
    var file_headers: bool = false;
    var imports: bool = false;
    var archive_symbols: bool = false;
    var archive_member_headers: bool = false;
    var elements: @FieldType(Options, "elements") = .initFill(true);
    var redact: @FieldType(Options, "redact") = .initFill(false);
    var relocs: bool = false;
    var section_headers: bool = false;
    var strings: bool = false;
    var symbols: bool = false;
    var tls: bool = false;
    var section_filters: std.ArrayList([]const u8) = .empty;
    var symbol_filters: std.ArrayList([]const u8) = .empty;
    var archive_member_filters: std.ArrayList([]const u8) = .empty;

    for (args[1..]) |arg| {
        if (!mem.startsWith(u8, arg, "-")) {
            try input_paths.append(arena, arg);
            continue;
        }

        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            Io.File.stdout().writeStreamingAll(io, usage) catch |err|
                fatal("failed to write stdout: {t}", .{err});
        } else if (mem.eql(u8, arg, "--all-headers")) {
            file_headers = true;
            archive_symbols = true;
            archive_member_headers = true;
            section_headers = true;
            symbols = true;
            relocs = true;
        } else if (mem.startsWith(u8, arg, "--exports")) {
            exports = true;
            archive_symbols = true;
            if (mem.eql(u8, arg["--exports".len..], "=sort"))
                exports_sort = true;
        } else if (mem.eql(u8, arg, "--file-headers")) {
            file_headers = true;
        } else if (mem.eql(u8, arg, "--imports")) {
            imports = true;
        } else if (mem.eql(u8, arg, "--archive-symbols")) {
            archive_symbols = true;
        } else if (mem.eql(u8, arg, "--archive-member-headers")) {
            archive_member_headers = true;
        } else if (mem.startsWith(u8, arg, "--elements=")) {
            elements = .initFill(false);
            var split = mem.splitScalar(u8, arg["--elements=".len..], ',');
            while (split.next()) |elem| {
                const kind, const add = if (elem.len > 0 and elem[0] == '-')
                    .{ elem[1..], false }
                else
                    .{ elem, true };

                if (std.meta.stringToEnum(Element, kind)) |format_kind| {
                    elements.set(format_kind, add);
                } else if (mem.eql(u8, kind, "all")) {
                    elements = .initFill(add);
                } else {
                    fatal("unrecognized element: '{s}'", .{kind});
                }
            }
        } else if (mem.startsWith(u8, arg, "--only-archive-member=")) {
            (try archive_member_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-archive-member=".len..]);
        } else if (mem.startsWith(u8, arg, "--only-section=")) {
            (try section_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-section=".len..]);
        } else if (mem.startsWith(u8, arg, "--only-symbol=")) {
            (try symbol_filters.addOne(arena)).* = try arena.dupe(u8, arg["--only-symbol=".len..]);
        } else if (mem.startsWith(u8, arg, "--redact=")) {
            const kind = arg["--redact=".len..];
            if (std.meta.stringToEnum(FieldKind, kind)) |field_kind| {
                redact.set(field_kind, true);
            } else if (mem.eql(u8, kind, "all")) {
                redact = .initFill(true);
            } else {
                fatal("unrecognized redaction kind: {s}", .{kind});
            }
        } else if (mem.eql(u8, arg, "--relocs")) {
            relocs = true;
        } else if (mem.eql(u8, arg, "--section-headers")) {
            section_headers = true;
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--snapshot")) {
            elements = .initFill(false);
            redact = .initFill(true);
        } else if (mem.eql(u8, arg, "--strings")) {
            strings = true;
        } else if (mem.eql(u8, arg, "--symbols")) {
            symbols = true;
        } else if (mem.eql(u8, arg, "--tls")) {
            tls = true;
        } else {
            fatal("unrecognized argument: {s}", .{arg});
        }
    }

    if (input_paths.items.len == 0) {
        fatal("missing input file path positional argument", .{});
    }

    const opts: Options = .{
        .exports = exports,
        .exports_sort = exports_sort,
        .file_headers = file_headers,
        .imports = imports,
        .archive_symbols = archive_symbols,
        .archive_member_headers = archive_member_headers,
        .archive_member_filters = archive_member_filters.items,
        .elements = elements,
        .redact = redact,
        .relocs = relocs,
        .section_filters = section_filters.items,
        .section_headers = section_headers,
        .strings = strings,
        .symbol_filters = symbol_filters.items,
        .symbols = symbols,
        .tls = tls,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    var any_errors: bool = false;

    for (input_paths.items) |input_path| {
        var file = std.Io.Dir.cwd().openFile(io, input_path, .{}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |open_err| {
                std.log.err("failed to open {q}: {t}", .{ input_path, open_err });
                continue;
            },
        };
        defer file.close(io);

        var file_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);

        var d: Objdump = .{
            .gpa = init.gpa,
            .opts = opts,
            .w = &stdout_writer.interface,
            .input_name = switch (opts.elements.get(.@"input-path")) {
                true => input_path,
                false => std.fs.path.basename(input_path),
            },

            .seek_base = 0,
            .raw_file_reader = &file_reader,
            .limited_reader = null,
        };

        d.dumpOne(input_path) catch |err| switch (err) {
            error.WriteFailed => switch (stdout_writer.err.?) {
                error.Canceled => |e| return e,
                else => |e| fatal("failed to write stdout: {t}", .{e}),
            },
            error.AlreadyReported => any_errors = true,
            else => |e| return e,
        };
        stdout_writer.flush() catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |e| fatal("failed to write stdout: {t}", .{e}),
        };
    }

    if (any_errors) {
        return 1;
    } else {
        return 0;
    }
}

const DumpOneError = Allocator.Error ||
    Io.Writer.Error ||
    Io.Cancelable ||
    Io.UnexpectedError ||
    error{AlreadyReported};

fn dumpOne(d: *Objdump, input_path: []const u8) DumpOneError!void {
    d.dumpOneInner() catch |err| switch (err) {
        error.ReadFailed => switch (d.raw_file_reader.err.?) {
            error.Canceled => |e| return e,
            else => |e| {
                try d.w.flush();
                std.log.err("failed to read {q}: {t}", .{ input_path, e });
                try d.w.writeByte('\n'); // trailing newline for this input
                return error.AlreadyReported;
            },
        },
        else => |e| return e,
    };
}
fn dumpOneInner(d: *Objdump) Objdump.Error!void {
    const r = d.reader();

    if (try archive.identify(r)) {
        return archive.dump(d);
    }
    try d.seekTo(0);

    return d.dumpNonArchive();
}
pub fn dumpNonArchive(d: *Objdump) Objdump.Error!void {
    const r = d.reader();

    if (try elf.identify(r)) {
        return elf.dump(d);
    }
    try d.seekTo(0);

    if (try macho.identify(r)) {
        return macho.dump(d);
    }
    try d.seekTo(0);

    if (try wasm.identify(r)) {
        return wasm.dump(d);
    }
    try d.seekTo(0);

    if (try coff.identifyImage(r)) {
        return coff.dumpImage(d);
    }
    try d.seekTo(0);

    if (try coff.identifyObject(r)) {
        return coff.dumpObject(d);
    }
    try d.seekTo(0);

    if (try coff.identifyImport(r)) {
        return coff.dumpImport(d);
    }
    try d.seekTo(0);

    return d.fail("unknown file format", .{});
}

const usage =
    \\Usage: zig objdump [options] file
    \\
    \\Options:
    \\  -h, --help                         Print this help and exit
    \\  --all-headers                      Alias for --file-headers --linker-member=2 --member-headers --section-headers --relocs --symbols
    \\  --exports[=sort]                   Display exported symbols. 
    \\                                     In the case of COFF import libraries, displays the symbol list and import headers.
    \\                                     Specify =sort to optionally sort the import headers by symbol name.
    \\  --file-headers                     Display file-format specific headers
    \\  --imports                          Display imported symbols
    \\  --archive-symbols                  Display contents of archive symbol table[s]
    \\  --archive-member-headers           Display archive member headers
    \\  --elements=[e1],[e2],-[e3],...     Select which formatting elements are displayed. Intended for snapshot testing.
    \\      file-type                      File type summary
    \\      header-name                    Name that precedes a header block     
    \\      input-path                     Display full input paths. If removed, only basenames will be used.
    \\      member-path                    Display full member paths. If removed, only basenames will be used.
    \\      newlines                       Newlines between output sections
    \\      table-header                   Table headers with column names
    \\      all                            (default) All of the above
    \\  --only-member=[name]               Only consider archive members names that contain [name]. Can be specified multiple times.
    \\  --only-section=[name]              Only consider section names that contain [name]. Can be specified multiple times.
    \\  --only-symbol=[name]               Only consider symbol names that contain [name]. Can be specified multiple times.
    \\  --redact=[kind]                    Redact the specified field kind. Intended for snapshot testing.
    \\      rva                            Relative virtual addresses
    \\      va                             Virtual addresses and file offsets
    \\      ord                            Symbol ordinals / hints
    \\      size                           Sizes and lengths
    \\      all                            All of the above
    \\  --relocs                           Display relocations
    \\  -s, --snapshot                     Alias for --redact=all --elements=-all
    \\  --section-headers                  Display section headers
    \\  --strings                          Display string tables
    \\  --symbols                          Display symbol tables
    \\  --tls                              Display TLS information
    \\
;
