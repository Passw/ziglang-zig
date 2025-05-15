const Spork8 = @This();
const builtin = @import("builtin");
const build_options = @import("build_options");

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Path = std.Build.Cache.Path;
const log = std.log.scoped(.link);

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Zcu = @import("../Zcu.zig");
const CodeGen = @import("../codegen/spork8/CodeGen.zig");
const codegen = @import("../codegen.zig");
const Mir = @import("../codegen/spork8/Mir.zig");
const link = @import("../link.zig");
const Compilation = @import("../Compilation.zig");
const Liveness = @import("../Air/Liveness.zig");
const dev = @import("../dev.zig");
const Value = @import("../Value.zig");

base: link.File,
funcs: std.AutoArrayHashMapUnmanaged(InternPool.Index, CodeGen.Function) = .empty,
/// All MIR instructions for all Zcu functions.
mir_instructions: std.MultiArrayList(Mir.Inst) = .{},
/// Corresponds to `mir_instructions`.
mir_extra: std.ArrayListUnmanaged(u32) = .empty,

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Spork8 {
    // TODO: restore saved linker state, don't truncate the file, and
    // participate in incremental compilation.
    return createEmpty(arena, comp, emit, options);
}

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Spork8 {
    const target = comp.root_mod.resolved_target.result;
    assert(target.ofmt == .spork8);
    assert(comp.config.output_mode == .Exe);
    const io = comp.io;

    const spork8 = try arena.create(Spork8);
    spork8.* = .{
        .base = .{
            .tag = .spork8,
            .comp = comp,
            .emit = emit,
            .gc_sections = options.gc_sections orelse true,
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse switch (target.os.tag) {
                .freestanding => 1 * 1024 * 1024, // 1 MiB
                else => 16 * 1024 * 1024, // 16 MiB
            },
            .allow_shlib_undefined = options.allow_shlib_undefined orelse false,
            .file = null,
            .build_id = options.build_id,
        },
    };
    errdefer spork8.base.destroy();

    spork8.base.file = try emit.root_dir.handle.createFile(io, emit.sub_path, .{
        .truncate = true,
        .read = true,
    });

    return spork8;
}

pub fn deinit(spork8: *Spork8) void {
    const gpa = spork8.base.comp.gpa;
    _ = gpa;
}

pub fn updateFunc(
    spork8: *Spork8,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    any_mir: *const codegen.AnyMir,
) !void {
    dev.check(.spork8_backend);
    // This linker implementation only works with codegen backend `.stage2_wasm`.
    const mir = &any_mir.spork8;
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const owner_nav = zcu.funcInfo(func_index).owner_nav;
    _ = gpa;
    _ = mir;
    _ = spork8;
    log.debug("updateFunc {f}", .{ip.getNav(owner_nav).fqn.fmt(ip)});
}

// Generate code for the "Nav", storing it in memory to be later written to
// the file on flush().
pub fn updateNav(spork8: *Spork8, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    _ = spork8;
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    log.debug("updateNav {f}", .{nav.fqn.fmt(ip)});
}

pub fn updateLineNumber(spork8: *Spork8, pt: Zcu.PerThread, ti_id: InternPool.TrackedInst.Index) !void {
    _ = spork8;
    _ = pt;
    _ = ti_id;
}

pub fn deleteExport(
    spork8: *Spork8,
    exported: Zcu.Exported,
    name: InternPool.NullTerminatedString,
) void {
    const zcu = spork8.base.comp.zcu.?;
    const ip = &zcu.intern_pool;
    const name_slice = name.toSlice(ip);
    switch (exported) {
        .nav => |nav_index| {
            log.debug("deleteExport '{s}' nav={d}", .{ name_slice, @backingInt(nav_index) });
        },
        .uav => |uav_index| {
            log.debug("deleteExport '{s}' uav={d}", .{ name_slice, @backingInt(uav_index) });
        },
    }
}

pub fn updateExports(
    spork8: *Spork8,
    pt: Zcu.PerThread,
    export_indices: []const Zcu.Export.Index,
) !void {
    _ = spork8;
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;

    for (export_indices) |export_idx| {
        const exp = export_idx.ptr(zcu);
        const name_slice = exp.opts.name.toSlice(ip);
        switch (exp.exported) {
            .nav => |nav_index| {
                log.debug("updateExports {q} nav={d}", .{ name_slice, @backingInt(nav_index) });
            },
            .uav => |uav_index| {
                log.debug("updateExports {q} uav={d}", .{ name_slice, @backingInt(uav_index) });
            },
        }
    }
}

pub fn loadInput(spork8: *Spork8, input: link.Input) !void {
    _ = input;
    const comp = spork8.base.comp;
    const diags = &comp.link_diags;
    return diags.failParse("spork8 does not support linking files together", .{});
}

pub fn flush(
    spork8: *Spork8,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.Error!void {
    const sub_prog_node = prog_node.start("Spork8 Flush", 0);
    defer sub_prog_node.end();

    _ = spork8;
    _ = arena;
    _ = tid;
    log.debug("TODO implement flush", .{});
}

pub fn prelink(spork8: *Spork8, prog_node: std.Progress.Node) link.Error!void {
    const sub_prog_node = prog_node.start("Spork8 Prelink", 0);
    defer sub_prog_node.end();

    _ = spork8;
}
