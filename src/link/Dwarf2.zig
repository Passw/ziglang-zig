lf: *link.File,
format: DW.Format,
endian: std.lang.Endian,
address_size: AddressSize,
const_pool: link.ConstPool,

units: std.array_hash_map.Auto(*Module, Unit),
/// Indices are `link.ConstPool.Index`.
values: std.ArrayList(struct {
    debug_info_ni: MappedFile.Node.Index,
}),
globals: std.array_hash_map.Auto(InternPool.Nav.Index, Global),
funcs: std.array_hash_map.Auto(InternPool.Nav.Index, Func),

debug_abbrev: DebugAbbrev,
frame: Frame,
debug_info: DebugInfo,
debug_line: DebugLine,
debug_line_str: String,
debug_str: String,
debug_str_offsets: StringOffsets,

pub const AddressSize = enum(u8) { @"32" = 4, @"64" = 8, _ };

pub const Unit = struct {
    frame_ni: MappedFile.Node.Index.Optional,
    cie_ni: MappedFile.Node.Index.Optional,
    debug_info_ni: MappedFile.Node.Index.Optional,
    debug_info_header_ni: MappedFile.Node.Index.Optional,
    debug_line_ni: MappedFile.Node.Index.Optional,
    debug_line_header_ni: MappedFile.Node.Index.Optional,

    pub const Index = enum(u32) {
        _,

        pub fn mod(ui: Unit.Index, dwarf: *Dwarf) *Module {
            return dwarf.units.keys()[@backingInt(ui)];
        }

        pub fn get(ui: Unit.Index, dwarf: *Dwarf) *Unit {
            return &dwarf.units.values()[@backingInt(ui)];
        }
    };
};

pub const Global = struct {
    debug_info_ni: MappedFile.Node.Index.Optional,

    pub const Index = enum(u32) {
        _,

        pub fn nav(gi: Global.Index, dwarf: *Dwarf) InternPool.Nav.Index {
            return dwarf.globals.keys()[@backingInt(gi)];
        }

        pub fn get(gi: Global.Index, dwarf: *Dwarf) *Global {
            return &dwarf.globals.values()[@backingInt(gi)];
        }
    };
};

pub const Func = struct {
    fde_ni: MappedFile.Node.Index.Optional,
    debug_info_ni: MappedFile.Node.Index.Optional,
    debug_line_ni: MappedFile.Node.Index.Optional,

    pub const Index = enum(u32) {
        _,

        pub fn nav(fi: Func.Index, dwarf: *Dwarf) InternPool.Nav.Index {
            return dwarf.funcs.keys()[@backingInt(fi)];
        }

        pub fn get(fi: Func.Index, dwarf: *Dwarf) *Func {
            return &dwarf.funcs.values()[@backingInt(fi)];
        }
    };
};

pub const Frame = struct {
    header: Header,

    pub const Header = struct {
        code_alignment_factor: u32,
        data_alignment_factor: i32,
        return_address_register: u32,
        initial_instructions: []const Cfa,
    };

    pub const Format = std.debug.Dwarf.Unwind.Section;
};

pub const DebugAbbrev = struct {
    ni: MappedFile.Node.Index.Optional,
    offset: usize,
    set: std.enums.EnumSet(AbbrevCode),
};

pub const DebugInfo = struct {};

pub const DebugLine = struct {
    header: Header,

    pub const Header = struct {
        minimum_instruction_length: u8,
        maximum_operations_per_instruction: u8,
        default_is_stmt: bool,
        line_base: i8,
        line_range: u8,
        opcode_base: u8,
    };
};

pub const String = struct {
    ni: MappedFile.Node.Index.Optional,
    offset: usize,
    map: std.AutoHashMapUnmanaged(usize, void),

    fn get(
        s: *String,
        gpa: std.mem.Allocator,
        mf: *MappedFile,
        string: []const u8,
    ) MappedFile.Error!usize {
        const ni = s.ni.unwrap().?;
        const gop = try s.map.getOrPutAdapted(gpa, string, Adapter{ .slice = ni.sliceConst(mf) });
        if (!gop.found_existing) {
            gop.key_ptr.* = s.offset;
            try ni.ensureMinimumSize(mf, gpa, s.offset + string.len + 1);
            const slice_mut = ni.slice(mf);
            @memcpy(slice_mut[s.offset..][0..string.len], string);
            s.offset += string.len;
            slice_mut[s.offset] = 0;
            s.offset += 1;
        }
        return gop.key_ptr.*;
    }

    const Adapter = struct {
        slice: []const u8,
        pub fn hash(_: Adapter, key: []const u8) u32 {
            return @truncate(std.hash.Wyhash.hash(0, key));
        }
        pub fn eql(adapter: Adapter, key: []const u8, rhs_offset: usize) bool {
            return std.mem.startsWith(u8, adapter.slice[rhs_offset..], key) and
                adapter.slice[rhs_offset + key.len] == 0;
        }
    };
};

pub const StringOffsets = struct {
    ni: MappedFile.Node.Index.Optional,
    offset: usize,
};

pub const SharedSection = enum { debug_abbrev, debug_line_str, debug_str, debug_str_offsets };

pub const Loc = union(enum) {
    empty,
    addr_reloc: link.File.SymbolId,
    deref: *const Loc,
    constu: u64,
    consts: i64,
    plus: Bin,
    reg: u32,
    breg: u32,
    push_object_address,
    call: struct {
        args: []const Loc = &.{},
        node: MappedFile.Node.Index,
    },
    form_tls_address: *const Loc,
    implicit_value: []const u8,
    stack_value: *const Loc,
    implicit_pointer: struct {
        node: MappedFile.Node.Index,
        offset: i65,
    },
    wasm_ext: union(enum) {
        local: u32,
        global: u32,
        operand_stack: u32,
    },

    pub const Bin = struct { *const Loc, *const Loc };

    fn getConst(loc: Loc, comptime Int: type) ?Int {
        return switch (loc) {
            .constu => |constu| std.math.cast(Int, constu),
            .consts => |consts| std.math.cast(Int, consts),
            else => null,
        };
    }

    fn getBaseReg(loc: Loc) ?u32 {
        return switch (loc) {
            .breg => |breg| breg,
            else => null,
        };
    }

    fn writeReg(reg: u32, op0: u8, opx: u8, writer: *Writer) Writer.Error!void {
        if (std.math.cast(u5, reg)) |small_reg| {
            try writer.writeByte(op0 + small_reg);
        } else {
            try writer.writeByte(opx);
            try writer.writeUleb128(reg);
        }
    }

    fn write(loc: Loc, adapter: anytype) link.EmitError!void {
        const writer = adapter.writer();
        switch (loc) {
            .empty => {},
            .addr_reloc => |si| {
                try writer.writeByte(DW.OP.addr);
                try adapter.addrSym(si);
            },
            .deref => |addr| {
                try addr.write(adapter);
                try writer.writeByte(DW.OP.deref);
            },
            .constu => |constu| if (std.math.cast(u5, constu)) |lit| {
                try writer.writeByte(@as(u8, DW.OP.lit0) + lit);
            } else if (std.math.cast(u8, constu)) |const1u| {
                try writer.writeAll(&.{ DW.OP.const1u, const1u });
            } else if (std.math.cast(u16, constu)) |const2u| {
                try writer.writeByte(DW.OP.const2u);
                try writer.writeInt(u16, const2u, adapter.endian());
            } else if (std.math.cast(u21, constu)) |const3u| {
                try writer.writeByte(DW.OP.constu);
                try writer.writeUleb128(const3u);
            } else if (std.math.cast(u32, constu)) |const4u| {
                try writer.writeByte(DW.OP.const4u);
                try writer.writeInt(u32, const4u, adapter.endian());
            } else if (std.math.cast(u49, constu)) |const7u| {
                try writer.writeByte(DW.OP.constu);
                try writer.writeUleb128(const7u);
            } else {
                try writer.writeByte(DW.OP.const8u);
                try writer.writeInt(u64, constu, adapter.endian());
            },
            .consts => |consts| if (std.math.cast(i8, consts)) |const1s| {
                try writer.writeAll(&.{ DW.OP.const1s, @bitCast(const1s) });
            } else if (std.math.cast(i16, consts)) |const2s| {
                try writer.writeByte(DW.OP.const2s);
                try writer.writeInt(i16, const2s, adapter.endian());
            } else if (std.math.cast(i21, consts)) |const3s| {
                try writer.writeByte(DW.OP.consts);
                try writer.writeSleb128(const3s);
            } else if (std.math.cast(i32, consts)) |const4s| {
                try writer.writeByte(DW.OP.const4s);
                try writer.writeInt(i32, const4s, adapter.endian());
            } else if (std.math.cast(i49, consts)) |const7s| {
                try writer.writeByte(DW.OP.consts);
                try writer.writeSleb128(const7s);
            } else {
                try writer.writeByte(DW.OP.const8s);
                try writer.writeInt(i64, consts, adapter.endian());
            },
            .plus => |plus| done: {
                if (plus[0].getConst(u0)) |_| {
                    try plus[1].write(adapter);
                    break :done;
                }
                if (plus[1].getConst(u0)) |_| {
                    try plus[0].write(adapter);
                    break :done;
                }
                if (plus[0].getBaseReg()) |breg| {
                    if (plus[1].getConst(i65)) |offset| {
                        try writeReg(breg, DW.OP.breg0, DW.OP.bregx, writer);
                        try writer.writeSleb128(offset);
                        break :done;
                    }
                }
                if (plus[1].getBaseReg()) |breg| {
                    if (plus[0].getConst(i65)) |offset| {
                        try writeReg(breg, DW.OP.breg0, DW.OP.bregx, writer);
                        try writer.writeSleb128(offset);
                        break :done;
                    }
                }
                if (plus[0].getConst(u64)) |uconst| {
                    try plus[1].write(adapter);
                    try writer.writeByte(DW.OP.plus_uconst);
                    try writer.writeUleb128(uconst);
                    break :done;
                }
                if (plus[1].getConst(u64)) |uconst| {
                    try plus[0].write(adapter);
                    try writer.writeByte(DW.OP.plus_uconst);
                    try writer.writeUleb128(uconst);
                    break :done;
                }
                try plus[0].write(adapter);
                try plus[1].write(adapter);
                try writer.writeByte(DW.OP.plus);
            },
            .reg => |reg| try writeReg(reg, DW.OP.reg0, DW.OP.regx, writer),
            .breg => |breg| {
                try writeReg(breg, DW.OP.breg0, DW.OP.bregx, writer);
                try writer.writeSleb128(0);
            },
            .push_object_address => try writer.writeByte(DW.OP.push_object_address),
            .call => |call| {
                for (call.args) |arg| try arg.write(adapter);
                try writer.writeByte(DW.OP.call_ref);
                try adapter.infoEntry(call.node);
            },
            .form_tls_address => |addr| {
                try addr.write(adapter);
                try writer.writeByte(DW.OP.form_tls_address);
            },
            .implicit_value => |value| {
                try writer.writeByte(DW.OP.implicit_value);
                try writer.writeUleb128(value.len);
                try writer.writeAll(value);
            },
            .stack_value => |value| {
                try value.write(adapter);
                try writer.writeByte(DW.OP.stack_value);
            },
            .implicit_pointer => |implicit_pointer| {
                try writer.writeByte(DW.OP.implicit_pointer);
                try adapter.infoEntry(implicit_pointer.node);
                try writer.writeSleb128(implicit_pointer.offset);
            },
            .wasm_ext => |wasm_ext| {
                try writer.writeByte(DW.OP.WASM_location);
                switch (wasm_ext) {
                    .local => |local| {
                        try writer.writeByte(DW.OP.WASM_local);
                        try writer.writeUleb128(local);
                    },
                    .global => |global| if (std.math.cast(u21, global)) |global_u21| {
                        try writer.writeByte(DW.OP.WASM_global);
                        try writer.writeUleb128(global_u21);
                    } else {
                        try writer.writeByte(DW.OP.WASM_global_u32);
                        try writer.writeInt(u32, global, adapter.endian());
                    },
                    .operand_stack => |operand_stack| {
                        try writer.writeByte(DW.OP.WASM_operand_stack);
                        try writer.writeUleb128(operand_stack);
                    },
                }
            },
        }
    }
};

pub const Cfa = union(enum) {
    nop,
    advance_loc: u32,
    offset: RegOff,
    rel_offset: RegOff,
    restore: u32,
    undefined: u32,
    same_value: u32,
    register: [2]u32,
    remember_state,
    restore_state,
    def_cfa: RegOff,
    def_cfa_register: u32,
    def_cfa_offset: i64,
    adjust_cfa_offset: i64,
    def_cfa_expression: Loc,
    expression: RegExpr,
    val_offset: RegOff,
    val_expression: RegExpr,
    escape: []const u8,

    const RegOff = struct { reg: u32, off: i64 };
    const RegExpr = struct { reg: u32, expr: Loc };

    fn write(cfa: Cfa, wip_nav: *WipNav) link.EmitError!void {
        const dfw = &wip_nav.fde_writer.interface;
        switch (cfa) {
            .nop => try dfw.writeByte(DW.CFA.nop),
            .advance_loc => |loc| {
                const delta =
                    @divExact(loc - wip_nav.cfi.loc, wip_nav.dwarf.frame.header.code_alignment_factor);
                if (delta == 0) {} else if (std.math.cast(u6, delta)) |small_delta|
                    try dfw.writeByte(@as(u8, DW.CFA.advance_loc) + small_delta)
                else if (std.math.cast(u8, delta)) |ubyte_delta|
                    try dfw.writeAll(&.{ DW.CFA.advance_loc1, ubyte_delta })
                else if (std.math.cast(u16, delta)) |uhalf_delta| {
                    try dfw.writeByte(DW.CFA.advance_loc2);
                    try dfw.writeInt(u16, uhalf_delta, wip_nav.dwarf.endian);
                } else if (std.math.cast(u32, delta)) |uword_delta| {
                    try dfw.writeByte(DW.CFA.advance_loc4);
                    try dfw.writeInt(u32, uword_delta, wip_nav.dwarf.endian);
                }
                wip_nav.cfi.loc = loc;
            },
            .offset, .rel_offset => |reg_off| {
                const factored_off = @divExact(reg_off.off - switch (cfa) {
                    else => unreachable,
                    .offset => 0,
                    .rel_offset => wip_nav.cfi.cfa.off,
                }, wip_nav.dwarf.frame.header.data_alignment_factor);
                if (std.math.cast(u63, factored_off)) |unsigned_off| {
                    if (std.math.cast(u6, reg_off.reg)) |small_reg| {
                        try dfw.writeByte(@as(u8, DW.CFA.offset) + small_reg);
                    } else {
                        try dfw.writeByte(DW.CFA.offset_extended);
                        try dfw.writeUleb128(reg_off.reg);
                    }
                    try dfw.writeUleb128(unsigned_off);
                } else {
                    try dfw.writeByte(DW.CFA.offset_extended_sf);
                    try dfw.writeUleb128(reg_off.reg);
                    try dfw.writeSleb128(factored_off);
                }
            },
            .restore => |reg| if (std.math.cast(u6, reg)) |small_reg|
                try dfw.writeByte(@as(u8, DW.CFA.restore) + small_reg)
            else {
                try dfw.writeByte(DW.CFA.restore_extended);
                try dfw.writeUleb128(reg);
            },
            .undefined => |reg| {
                try dfw.writeByte(DW.CFA.undefined);
                try dfw.writeUleb128(reg);
            },
            .same_value => |reg| {
                try dfw.writeByte(DW.CFA.same_value);
                try dfw.writeUleb128(reg);
            },
            .register => |regs| if (regs[0] != regs[1]) {
                try dfw.writeByte(DW.CFA.register);
                for (regs) |reg| try dfw.writeUleb128(reg);
            } else {
                try dfw.writeByte(DW.CFA.same_value);
                try dfw.writeUleb128(regs[0]);
            },
            .remember_state => try dfw.writeByte(DW.CFA.remember_state),
            .restore_state => try dfw.writeByte(DW.CFA.restore_state),
            .def_cfa, .def_cfa_register, .def_cfa_offset, .adjust_cfa_offset => {
                const reg_off: RegOff = switch (cfa) {
                    else => unreachable,
                    .def_cfa => |reg_off| reg_off,
                    .def_cfa_register => |reg| .{ .reg = reg, .off = wip_nav.cfi.cfa.off },
                    .def_cfa_offset => |off| .{ .reg = wip_nav.cfi.cfa.reg, .off = off },
                    .adjust_cfa_offset => |off| .{
                        .reg = wip_nav.cfi.cfa.reg,
                        .off = wip_nav.cfi.cfa.off + off,
                    },
                };
                const changed_reg = reg_off.reg != wip_nav.cfi.cfa.reg;
                const unsigned_off = std.math.cast(u63, reg_off.off);
                if (reg_off.off == wip_nav.cfi.cfa.off) {
                    if (changed_reg) {
                        try dfw.writeByte(DW.CFA.def_cfa_register);
                        try dfw.writeUleb128(reg_off.reg);
                    }
                } else if (switch (wip_nav.dwarf.frame.header.data_alignment_factor) {
                    0 => unreachable,
                    1 => unsigned_off != null,
                    else => |data_alignment_factor| @rem(reg_off.off, data_alignment_factor) != 0,
                }) {
                    try dfw.writeByte(if (changed_reg) DW.CFA.def_cfa else DW.CFA.def_cfa_offset);
                    if (changed_reg) try dfw.writeUleb128(reg_off.reg);
                    try dfw.writeUleb128(unsigned_off.?);
                } else {
                    try dfw.writeByte(if (changed_reg) DW.CFA.def_cfa_sf else DW.CFA.def_cfa_offset_sf);
                    if (changed_reg) try dfw.writeUleb128(reg_off.reg);
                    try dfw.writeSleb128(
                        @divExact(reg_off.off, wip_nav.dwarf.frame.header.data_alignment_factor),
                    );
                }
                wip_nav.cfi.cfa = reg_off;
            },
            .def_cfa_expression => |expr| {
                try dfw.writeByte(DW.CFA.def_cfa_expression);
                try wip_nav.frameExprLoc(expr);
            },
            .expression => |reg_expr| {
                try dfw.writeByte(DW.CFA.expression);
                try dfw.writeUleb128(reg_expr.reg);
                try wip_nav.frameExprLoc(reg_expr.expr);
            },
            .val_offset => |reg_off| {
                const factored_off =
                    @divExact(reg_off.off, wip_nav.dwarf.frame.header.data_alignment_factor);
                if (std.math.cast(u63, factored_off)) |unsigned_off| {
                    try dfw.writeByte(DW.CFA.val_offset);
                    try dfw.writeUleb128(reg_off.reg);
                    try dfw.writeUleb128(unsigned_off);
                } else {
                    try dfw.writeByte(DW.CFA.val_offset_sf);
                    try dfw.writeUleb128(reg_off.reg);
                    try dfw.writeSleb128(factored_off);
                }
            },
            .val_expression => |reg_expr| {
                try dfw.writeByte(DW.CFA.val_expression);
                try dfw.writeUleb128(reg_expr.reg);
                try wip_nav.frameExprLoc(reg_expr.expr);
            },
            .escape => |bytes| try dfw.writeAll(bytes),
        }
    }
};

pub const WipNav = struct {
    dwarf: *Dwarf,
    unit: Unit.Index,
    func: ?Func.Index,
    func_si: link.File.SymbolId,
    cfi: struct {
        loc: u32,
        cfa: Cfa.RegOff,
    },
    frame_format: Frame.Format,
    fde_writer: MappedFile.Node.Writer,
    frame_func_length: struct { offset: usize, size: AddressSize },

    pub const Debug = struct {
        wip_nav: WipNav,
        pt: Zcu.PerThread,
        any_children: bool,
        blocks: std.ArrayList(struct {
            abbrev_code: u32,
            low_pc_off: u64,
            high_pc: u32,
        }),
        info_writer: MappedFile.Node.Writer,
        line_writer: MappedFile.Node.Writer,

        pub fn deinit(debug: *Debug) void {
            const gpa = debug.pt.zcu.gpa;
            debug.line_writer.deinit();
            debug.info_writer.deinit();
            debug.blocks.deinit(gpa);
            debug.wip_nav.deinit();
            debug.* = undefined;
        }

        pub fn startDebugInfo(debug: *Debug) link.Error!void {
            debug.startDebugInfoInner() catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| return e,
            };
        }
        fn startDebugInfoInner(debug: *Debug) link.EmitError!void {
            const dwarf = debug.wip_nav.dwarf;
            const ip = &debug.pt.zcu.intern_pool;
            const nav = ip.getNav(debug.wip_nav.func.?.nav(dwarf));
            const diw = &debug.info_writer.interface;
            try diw.writeUleb128(try dwarf.refAbbrevCode(.decl_func));
            try debug.strp(nav.name.toSlice(ip));
            try debug.strp(nav.fqn.toSlice(ip));
        }

        pub fn genDebugFrame(debug: *Debug, loc: u32, cfa: Cfa) link.Error!void {
            return debug.wip_nav.genDebugFrame(loc, cfa);
        }

        pub fn finishFunc(debug: *Debug) link.Error!void {
            assert(debug.wip_nav.func != null);
            debug.finishDebugInfo() catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| return e,
            };
            const dlw = &debug.line_writer.interface;
            dlw.rebase(dlw.end, comptime 1 + uleb128Bytes(1) + 1) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
            };
        }

        fn finishDebugInfo(debug: *Debug) link.EmitError!void {
            const diw = &debug.info_writer.interface;
            try diw.writeUleb128(@backingInt(AbbrevCode.null));
            try debug.wip_nav.dwarf.genDebugInfoPadding(diw, diw.unusedCapacityLen());
        }

        pub const LocalVarTag = enum { arg, local_var };
        pub fn genLocalVarDebugInfo(
            debug: *Debug,
            tag: LocalVarTag,
            opt_name: ?[]const u8,
            ty: Type,
            loc: Loc,
        ) link.Error!void {
            if (true) return;
            return debug.genLocalVarDebugInfoInner(tag, opt_name, ty, loc) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn genLocalVarDebugInfoInner(
            debug: *Debug,
            tag: LocalVarTag,
            opt_name: ?[]const u8,
            ty: Type,
            loc: Loc,
        ) link.EmitError!void {
            assert(debug.wip_nav.func != null);
            try debug.abbrevCode(switch (tag) {
                .arg => if (opt_name) |_| .arg else .unnamed_arg,
                .local_var => if (opt_name) |_| .local_var else unreachable,
            });
            if (opt_name) |name| try debug.strp(name);
            try debug.refType(ty);
            try debug.infoExprLoc(loc);
            debug.any_children = true;
        }

        pub const LocalConstTag = enum { comptime_arg, local_const };
        pub fn genLocalConstDebugInfo(
            debug: *Debug,
            tag: LocalConstTag,
            opt_name: ?[]const u8,
            val: Value,
        ) link.Error!void {
            if (true) return;
            return debug.genLocalConstDebugInfoInner(tag, opt_name, val) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn genLocalConstDebugInfoInner(
            debug: *Debug,
            tag: LocalConstTag,
            opt_name: ?[]const u8,
            val: Value,
        ) link.EmitError!void {
            assert(debug.wip_nav.func != null);
            const zcu = debug.pt.zcu;
            const ty = val.typeOf(zcu);
            const has_runtime_bits = ty.hasRuntimeBits(zcu);
            const has_comptime_state = ty.comptimeOnly(zcu);
            try debug.abbrevCode(if (has_runtime_bits and has_comptime_state) switch (tag) {
                .comptime_arg => if (opt_name) |_| .comptime_arg_runtime_bits_comptime_state else .unnamed_comptime_arg_runtime_bits_comptime_state,
                .local_const => if (opt_name) |_| .local_const_runtime_bits_comptime_state else unreachable,
            } else if (has_comptime_state) switch (tag) {
                .comptime_arg => if (opt_name) |_| .comptime_arg_comptime_state else .unnamed_comptime_arg_comptime_state,
                .local_const => if (opt_name) |_| .local_const_comptime_state else unreachable,
            } else if (has_runtime_bits) switch (tag) {
                .comptime_arg => if (opt_name) |_| .comptime_arg_runtime_bits else .unnamed_comptime_arg_runtime_bits,
                .local_const => if (opt_name) |_| .local_const_runtime_bits else unreachable,
            } else switch (tag) {
                .comptime_arg => if (opt_name) |_| .comptime_arg else .unnamed_comptime_arg,
                .local_const => if (opt_name) |_| .local_const else unreachable,
            });
            if (opt_name) |name| try debug.strp(name);
            try debug.refType(ty);
            if (has_runtime_bits) try debug.blockValue(val);
            if (has_comptime_state) try debug.refValue(val);
            debug.any_children = true;
        }

        pub fn genVarArgsDebugInfo(debug: *Debug) link.Error!void {
            if (true) return;
            return debug.genVarArgsDebugInfoInner() catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn genVarArgsDebugInfoInner(debug: *Debug) link.EmitError!void {
            assert(debug.wip_nav.func != null);
            try debug.abbrevCode(.is_var_args);
            debug.any_children = true;
        }

        pub fn advancePcAndLine(debug: *Debug, delta_line: i33, delta_pc: u64) link.Error!void {
            if (true) return;
            return debug.advancePcAndLineInner(delta_line, delta_pc) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
            };
        }
        fn advancePcAndLineInner(debug: *Debug, delta_line: i33, delta_pc: u64) Writer.Error!void {
            const dlw = &debug.line_writer.interface;

            const header = debug.wip_nav.dwarf.debug_line.header;
            assert(header.maximum_operations_per_instruction == 1);
            const delta_op: u64 = 0;

            const remaining_delta_line: i9 = @intCast(if (delta_line < header.line_base or
                delta_line - header.line_base >= header.line_range)
            remaining: {
                assert(delta_line != 0);
                try dlw.writeByte(DW.LNS.advance_line);
                try dlw.writeSleb128(delta_line);
                break :remaining 0;
            } else delta_line);

            const op_advance = @divExact(delta_pc, header.minimum_instruction_length) *
                header.maximum_operations_per_instruction + delta_op;
            const max_op_advance: u9 = (std.math.maxInt(u8) - header.opcode_base) / header.line_range;
            const remaining_op_advance: u8 = @intCast(if (op_advance >= 2 * max_op_advance) remaining: {
                try dlw.writeByte(DW.LNS.advance_pc);
                try dlw.writeUleb128(op_advance);
                break :remaining 0;
            } else if (op_advance >= max_op_advance) remaining: {
                try dlw.writeByte(DW.LNS.const_add_pc);
                break :remaining op_advance - max_op_advance;
            } else op_advance);

            if (remaining_delta_line == 0 and remaining_op_advance == 0)
                try dlw.writeByte(DW.LNS.copy)
            else
                try dlw.writeByte(@intCast((remaining_delta_line - header.line_base) +
                    (header.line_range * remaining_op_advance) + header.opcode_base));
        }

        pub fn setColumn(debug: *Debug, column: u32) link.Error!void {
            if (true) return;
            return debug.setColumnInner(column) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
            };
        }
        fn setColumnInner(debug: *Debug, column: u32) Writer.Error!void {
            const dlw = &debug.line_writer.interface;
            try dlw.writeByte(DW.LNS.set_column);
            try dlw.writeUleb128(column + 1);
        }

        pub fn negateStmt(debug: *Debug) link.Error!void {
            if (true) return;
            return debug.negateStmtInner() catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
            };
        }
        fn negateStmtInner(debug: *Debug) Writer.Error!void {
            try debug.line_writer.interface.writeByte(DW.LNS.negate_stmt);
        }

        pub fn setPrologueEnd(debug: *Debug) link.Error!void {
            if (true) return;
            return debug.setPrologueEndInner() catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
            };
        }
        fn setPrologueEndInner(debug: *Debug) Writer.Error!void {
            try debug.line_writer.interface.writeByte(DW.LNS.set_prologue_end);
        }

        pub fn setEpilogueBegin(debug: *Debug) link.Error!void {
            if (true) return;
            return debug.setEpilogueBeginInner() catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
            };
        }
        fn setEpilogueBeginInner(debug: *Debug) Writer.Error!void {
            try debug.line_writer.interface.writeByte(DW.LNS.set_epilogue_begin);
        }

        pub fn enterBlock(debug: *Debug, code_off: u64) link.Error!void {
            if (true) return;
            return debug.enterBlockInner(code_off) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn enterBlockInner(debug: *Debug, code_off: u64) link.EmitError!void {
            const dwarf = debug.wip_nav.dwarf;
            const diw = &debug.info_writer.interface;
            const block = try debug.blocks.addOne(dwarf.lf.comp.gpa);

            block.abbrev_code = @intCast(diw.end);
            try debug.abbrevCode(.block);
            block.low_pc_off = code_off;
            try debug.infoAddrSym(debug.wip_nav.func_si, code_off);
            block.high_pc = @intCast(diw.end);
            try diw.writeInt(u32, 0, dwarf.endian);
            debug.any_children = false;
        }

        pub fn leaveBlock(debug: *Debug, code_off: u64) link.Error!void {
            if (true) return;
            return debug.leaveBlockInner(code_off) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn leaveBlockInner(debug: *Debug, code_off: u64) link.EmitError!void {
            const dwarf = debug.wip_nav.dwarf;
            const block_bytes = comptime uleb128Bytes(@backingInt(AbbrevCode.block));
            const block = debug.blocks.pop().?;
            if (debug.any_children)
                try debug.info_writer.interface.writeUleb128(@backingInt(AbbrevCode.null))
            else
                std.leb.writeUnsignedFixed(
                    block_bytes,
                    debug.info_writer.interface.buffered()[block.abbrev_code..][0..block_bytes],
                    @intCast(try dwarf.refAbbrevCode(.empty_block)),
                );
            std.mem.writeInt(
                u32,
                debug.info_writer.interface.buffered()[block.high_pc..][0..4],
                @intCast(code_off - block.low_pc_off),
                dwarf.endian,
            );
            debug.any_children = true;
        }

        pub fn enterInlineFunc(
            debug: *Debug,
            func: InternPool.Index,
            code_off: u64,
            line: u32,
            column: u32,
        ) link.Error!void {
            if (true) return;
            return debug.enterInlineFuncInner(func, code_off, line, column) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn enterInlineFuncInner(
            debug: *Debug,
            func: InternPool.Index,
            code_off: u64,
            line: u32,
            column: u32,
        ) link.EmitError!void {
            const dwarf = debug.wip_nav.dwarf;
            const zcu = debug.pt.zcu;
            const diw = &debug.info_writer.interface;
            const block = try debug.blocks.addOne(zcu.gpa);

            block.abbrev_code = @intCast(diw.end);
            try debug.abbrevCode(.inlined_func);
            try debug.refNav(zcu.funcInfo(func).owner_nav);
            try diw.writeUleb128(zcu.navSrcLine(debug.wip_nav.func.?.nav(dwarf)) + line + 1);
            try diw.writeUleb128(column + 1);
            block.low_pc_off = code_off;
            try debug.infoAddrSym(debug.wip_nav.func_si, code_off);
            block.high_pc = @intCast(diw.end);
            try diw.writeInt(u32, 0, dwarf.endian);
            try debug.setInlineFunc(func);
            debug.any_children = false;
        }

        pub fn leaveInlineFunc(debug: *Debug, func: InternPool.Index, code_off: u64) link.Error!void {
            if (true) return;
            return debug.leaveInlineFuncInner(func, code_off) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.info_writer),
                else => |e| e,
            };
        }
        fn leaveInlineFuncInner(
            debug: *Debug,
            func: InternPool.Index,
            code_off: u64,
        ) link.EmitError!void {
            const dwarf = debug.wip_nav.dwarf;
            const inlined_func_bytes = comptime uleb128Bytes(@backingInt(AbbrevCode.inlined_func));
            const block = debug.blocks.pop().?;
            const diw = &debug.info_writer.interface;
            if (debug.any_children)
                try diw.writeUleb128(@backingInt(AbbrevCode.null))
            else
                std.leb.writeUnsignedFixed(
                    inlined_func_bytes,
                    diw.buffered()[block.abbrev_code..][0..inlined_func_bytes],
                    @intCast(try dwarf.refAbbrevCode(.empty_inlined_func)),
                );
            std.mem.writeInt(
                u32,
                diw.buffered()[block.high_pc..][0..4],
                @intCast(code_off - block.low_pc_off),
                dwarf.endian,
            );
            try debug.setInlineFunc(func);
            debug.any_children = true;
        }

        pub fn setInlineFunc(debug: *Debug, func: InternPool.Index) link.Error!void {
            return debug.setInlineFuncInner(func) catch |err| switch (err) {
                error.WriteFailed => return debug.wip_nav.reportWriteError(&debug.line_writer),
                else => |e| e,
            };
        }
        fn setInlineFuncInner(debug: *Debug, func: InternPool.Index) link.EmitError!void {
            const wip_nav = &debug.wip_nav;
            const zcu = debug.pt.zcu;
            const dwarf = wip_nav.dwarf;

            const func_index = try dwarf.getFunc(zcu.funcInfo(func).owner_nav);
            if (wip_nav.func == func_index) return;

            if (true) @panic("TODO");
            const new_func_info = zcu.funcInfo(func);
            const new_file = zcu.navFileScopeIndex(new_func_info.owner_nav);
            const new_unit = try dwarf.getUnit(zcu.fileByIndex(new_file).mod.?);

            const dlw = &debug.line_writer.interface;
            if (zcu.comp.config.incremental) {
                const new_func_gop = try dwarf.funcs.getOrPut(zcu.gpa, new_func_info.owner_nav);
                errdefer _ = if (!new_func_gop.found_existing) dwarf.funcs.pop();
                if (!new_func_gop.found_existing) new_func_gop.value_ptr.* = .{
                    .frame_node = .none,
                    .debug_info_node = .none,
                    .debug_line_node = .none,
                };

                const section_offset_size: u4 = switch (dwarf.format) {
                    .@"32" => 4,
                    .@"64" => 8,
                };

                try dlw.writeByte(DW.LNS.extended_op);
                try dlw.writeUleb128(1 + section_offset_size);
                try dlw.writeByte(DW.LNE.ZIG_set_decl);
                try dwarf.debug_line.section.getUnit(wip_nav.unit).getEntry(wip_nav.entry).cross_section_relocs.append(zcu.gpa, .{
                    .source_off = @bitCast(@as(u64, dlw.end)),
                    .target_sec = .debug_info,
                    .target_unit = new_unit,
                    .target_entry = new_func_gop.value_ptr.toOptional(),
                });
                try dlw.splatByteAll(0, section_offset_size);
                return;
            }

            const old_func_info = zcu.funcInfo(wip_nav.func);
            const old_file = zcu.navFileScopeIndex(old_func_info.owner_nav);
            if (old_file != new_file) {
                const mod_info = dwarf.getModInfo(wip_nav.unit);
                try mod_info.dirs.put(zcu.gpa, new_unit, {});
                const file_gop = try mod_info.files.getOrPut(zcu.gpa, new_file);

                try dlw.writeByte(DW.LNS.set_file);
                try dlw.writeUleb128(file_gop.index);
            }

            const old_src_line: i33 = zcu.navSrcLine(old_func_info.owner_nav);
            const new_src_line: i33 = zcu.navSrcLine(new_func_info.owner_nav);
            if (new_src_line != old_src_line) {
                try dlw.writeByte(DW.LNS.advance_line);
                try dlw.writeSleb128(new_src_line - old_src_line);
            }

            wip_nav.func = func;
        }

        fn abbrevCode(debug: *Debug, abbrev_code: AbbrevCode) link.EmitError!void {
            try debug.info_writer.interface.writeUleb128(
                try debug.wip_nav.dwarf.refAbbrevCode(abbrev_code),
            );
        }

        fn infoExternalReloc(debug: *Debug, reloc: struct {
            source_off: u32 = 0,
            target_si: link.File.SymbolId,
            target_off: u64 = 0,
        }) std.mem.Allocator.Error!void {
            if (true) @panic("TODO");
            try debug.wip_nav.externalReloc(&debug.wip_nav.dwarf.debug_frame.section, reloc);
        }

        fn infoSectionOffset(
            debug: *Debug,
            target_ni: MappedFile.Node.Index,
            addend: i64,
        ) link.EmitError!void {
            try debug.wip_nav.dwarf.sectionOffset(&debug.info_writer, target_ni, addend);
        }

        fn strp(debug: *Debug, str: []const u8) link.EmitError!void {
            const dwarf = debug.wip_nav.dwarf;
            try dwarf.strp(&dwarf.debug_str, &debug.info_writer, str);
        }

        fn strpFmt(debug: *Debug, comptime fmt: []const u8, args: anytype) link.EmitError!void {
            const gpa = debug.pt.zcu.gpa;
            const str = try std.fmt.allocPrint(gpa, fmt, args);
            defer gpa.free(str);
            try debug.strp(str);
        }

        fn infoExprLoc(debug: *Debug, loc: Loc) link.EmitError!void {
            var buf: [64]u8 = undefined;
            var counter: ExprLocCounter = .init(debug.wip_nav.dwarf, &buf);
            try loc.write(&counter);

            const adapter: struct {
                debug: *Debug,
                fn writer(ctx: @This()) *Writer {
                    return &ctx.debug.info_writer.interface;
                }
                fn endian(ctx: @This()) std.lang.Endian {
                    return ctx.debug.wip_nav.dwarf.endian;
                }
                fn addrSym(ctx: @This(), si: link.File.SymbolId) link.EmitError!void {
                    try ctx.debug.infoAddrSym(si, 0);
                }
                fn infoEntry(ctx: @This(), node: MappedFile.Node.Index) link.EmitError!void {
                    try ctx.debug.infoSectionOffset(node, 0);
                }
            } = .{ .debug = debug };
            try adapter.writer().writeUleb128(counter.dw.fullCount());
            try loc.write(adapter);
        }

        fn infoAddrSym(
            debug: *Debug,
            si: link.File.SymbolId,
            sym_off: u64,
        ) link.EmitError!void {
            const diw = &debug.info_writer.interface;
            try debug.infoExternalReloc(.{
                .source_off = @bitCast(@as(u64, diw.end)),
                .target_si = si,
                .target_off = sym_off,
            });
            try diw.splatByteAll(0, @backingInt(debug.wip_nav.dwarf.address_size));
        }

        fn refNav(debug: *Debug, nav_index: InternPool.Nav.Index) link.EmitError!void {
            try debug.infoSectionOffset(try debug.wip_nav.dwarf.getNavNode(nav_index), 0);
        }

        fn refType(debug: *Debug, ty: Type) link.EmitError!void {
            return debug.refValue(ty.toValue());
        }

        fn refValue(debug: *Debug, value: Value) link.EmitError!void {
            try debug.infoSectionOffset(.debug_info, try debug.getValueNode(value), 0);
        }

        fn getValueNode(debug: *Debug, value: Value) link.Error!MappedFile.Node.Index {
            if (value.typeOf(debug.zcu).toIntern() != .type_type) {
                assert(value.typeOf(debug.zcu).comptimeOnly(debug.zcu));
            }
            const dwarf = debug.wip_nav.dwarf;
            const index = try dwarf.const_pool.get(debug.pt, .{ .dwarf = dwarf }, value.toIntern());
            return dwarf.values.items[@backingInt(index)];
        }

        fn blockValue(debug: *Debug, val: Value) link.EmitError!void {
            const ty = val.typeOf(debug.pt.zcu);
            const diw = &debug.info_writer.interface;
            const size = ty.abiSize(debug.pt.zcu);
            try diw.writeUleb128(size);
            if (size == 0) return;
            const old_end = diw.end;
            try codegen.generateSymbol(
                debug.wip_nav.dwarf.lf,
                debug.pt,
                val,
                diw,
                .{ .debug_output = .{ .dwarf2 = debug } },
            );
            if (old_end + size != diw.end) {
                std.debug.print("{f} [{}]: {} != {}\n", .{
                    ty.fmt(debug.pt),
                    ty.toIntern(),
                    size,
                    diw.end - old_end,
                });
                unreachable;
            }
        }
    };

    pub fn deinit(wip_nav: *WipNav) void {
        wip_nav.fde_writer.deinit();
        wip_nav.* = undefined;
    }

    pub fn genDebugFrameHeader(wip_nav: *WipNav) link.Error!void {
        wip_nav.genDebugFrameHeaderInner() catch |err| switch (err) {
            error.WriteFailed => return wip_nav.reportWriteError(&wip_nav.fde_writer),
            else => |e| return e,
        };
    }
    fn genDebugFrameHeaderInner(wip_nav: *WipNav) link.EmitError!void {
        assert(wip_nav.func != null);
        const dwarf = wip_nav.dwarf;
        const dfw = &wip_nav.fde_writer.interface;
        try dwarf.genUnitLength(dfw);
        switch (wip_nav.frame_format) {
            .eh_frame => {
                try dfw.writeInt(u32, undefined, dwarf.endian);
                {
                    const offset = dfw.end;
                    try dfw.writeInt(u32, 0, dwarf.endian);
                    const elf = dwarf.lf.cast(.elf2).?;
                    try elf.addReloc(
                        @bitCast(wip_nav.fde_writer.ni),
                        offset,
                        wip_nav.func_si,
                        0,
                        .rel32(elf),
                    );
                }
                wip_nav.frame_func_length = .{ .offset = dfw.end, .size = .@"32" };
                try dfw.writeInt(u32, undefined, dwarf.endian);
                try dfw.writeUleb128(0);
            },
            .debug_frame => {
                try wip_nav.frameSectionOffset(wip_nav.unit.get(dwarf).cie_ni.unwrap().?, 0);
                try wip_nav.frameAddrSym(wip_nav.func_si, 0);
                wip_nav.frame_func_length = .{ .offset = dfw.end, .size = dwarf.address_size };
                try dfw.splatByteAll(undefined, @backingInt(dwarf.address_size));
            },
        }
    }

    pub fn genDebugFrame(wip_nav: *WipNav, loc: u32, cfa: Cfa) link.Error!void {
        return wip_nav.genDebugFrameInner(loc, cfa) catch |err| switch (err) {
            error.WriteFailed => return wip_nav.reportWriteError(&wip_nav.fde_writer),
            else => |e| return e,
        };
    }
    fn genDebugFrameInner(wip_nav: *WipNav, loc: u32, cfa: Cfa) link.EmitError!void {
        assert(wip_nav.func != null);
        const loc_cfa: Cfa = .{ .advance_loc = loc };
        try loc_cfa.write(wip_nav);
        try cfa.write(wip_nav);
    }

    pub fn finishDebugFrameFde(wip_nav: *WipNav, func_length: u64) void {
        const dwarf = wip_nav.dwarf;
        const dfw = &wip_nav.fde_writer.interface;
        switch (wip_nav.frame_func_length.size) {
            _ => unreachable,
            .@"32" => std.mem.writeInt(
                u32,
                dfw.buffered()[wip_nav.frame_func_length.offset..][0..4],
                @intCast(func_length),
                dwarf.endian,
            ),
            .@"64" => std.mem.writeInt(
                u64,
                dfw.buffered()[wip_nav.frame_func_length.offset..][0..8],
                func_length,
                dwarf.endian,
            ),
        }
        @memset(dfw.unusedCapacitySlice(), DW.CFA.nop);
    }

    const ExprLocCounter = struct {
        dw: Writer.Discarding,
        section_offset_bytes: u32,
        address_size: AddressSize,
        fn init(dwarf: *Dwarf, buf: []u8) ExprLocCounter {
            return .{
                .dw = .init(buf),
                .section_offset_bytes = switch (dwarf.format) {
                    .@"32" => 4,
                    .@"64" => 8,
                },
                .address_size = dwarf.address_size,
            };
        }
        fn writer(counter: *ExprLocCounter) *Writer {
            return &counter.dw.writer;
        }
        fn endian(_: ExprLocCounter) std.lang.Endian {
            return .native;
        }
        fn addrSym(counter: *ExprLocCounter, _: link.File.SymbolId) Writer.Error!void {
            try counter.dw.writer.splatByteAll(undefined, @backingInt(counter.address_size));
        }
        fn infoEntry(counter: *ExprLocCounter, _: MappedFile.Node.Index) Writer.Error!void {
            try counter.dw.writer.splatByteAll(undefined, counter.section_offset_bytes);
        }
    };

    fn frameSectionOffset(
        wip_nav: *WipNav,
        target_ni: MappedFile.Node.Index,
        addend: usize,
    ) link.EmitError!void {
        try wip_nav.dwarf.sectionOffset(&wip_nav.fde_writer, target_ni, addend);
    }

    fn frameExprLoc(wip_nav: *WipNav, loc: Loc) link.EmitError!void {
        var buf: [64]u8 = undefined;
        var counter: ExprLocCounter = .init(wip_nav.dwarf, &buf);
        try loc.write(&counter);

        const adapter: struct {
            wip_nav: *WipNav,
            fn writer(ctx: @This()) *Writer {
                return &ctx.wip_nav.fde_writer.interface;
            }
            fn endian(ctx: @This()) std.lang.Endian {
                return ctx.wip_nav.dwarf.endian;
            }
            fn addrSym(ctx: @This(), si: link.File.SymbolId) link.EmitError!void {
                try ctx.wip_nav.frameAddrSym(si, 0);
            }
            fn infoEntry(ctx: @This(), node: MappedFile.Node.Index) link.EmitError!void {
                try ctx.wip_nav.frameSectionOffset(node, 0);
            }
        } = .{ .wip_nav = wip_nav };
        try adapter.writer().writeUleb128(counter.dw.fullCount());
        try loc.write(adapter);
    }

    fn frameAddrSym(
        wip_nav: *WipNav,
        si: link.File.SymbolId,
        sym_off: u64,
    ) link.EmitError!void {
        const dwarf = wip_nav.dwarf;
        const dfw = &wip_nav.fde_writer.interface;
        const offset = dfw.end;
        try dfw.splatByteAll(0, @backingInt(dwarf.address_size));
        const elf = dwarf.lf.cast(.elf2).?;
        try elf.addReloc(
            @bitCast(wip_nav.fde_writer.ni),
            offset,
            si,
            @bitCast(sym_off),
            switch (dwarf.format) {
                .@"32" => .abs32(elf),
                .@"64" => .abs64(elf),
            },
        );
    }

    fn reportWriteError(wip_nav: *WipNav, mfnw: *const MappedFile.Node.Writer) link.Error {
        switch (mfnw.err.?) {
            else => |e| return e,
            error.MappedFileIo => return wip_nav.dwarf.lf.comp.link_diags.fail(
                "failed to write output file: {t}",
                .{mfnw.mf.io_err.?},
            ),
        }
    }
};

pub fn init(lf: *link.File, format: DW.Format) Dwarf {
    const target = &lf.comp.root_mod.resolved_target.result;
    return .{
        .lf = lf,
        .format = format,
        .address_size = switch (target.ptrBitWidth()) {
            0...32 => .@"32",
            33...64 => .@"64",
            else => unreachable,
        },
        .endian = target.cpu.arch.endian(),
        .const_pool = .empty,
        .units = .empty,
        .values = .empty,
        .globals = .empty,
        .funcs = .empty,

        .debug_abbrev = .{
            .ni = .none,
            .offset = 0,
            .set = .empty,
        },
        .frame = .{
            .header = if (target.cpu.arch == .x86_64 and target.ofmt == .elf) header: {
                dev.check(.x86_64_backend);
                const Register = @import("../codegen/x86_64/bits.zig").Register;
                break :header comptime .{
                    .code_alignment_factor = 1,
                    .data_alignment_factor = -8,
                    .return_address_register = Register.rip.dwarfNum(),
                    .initial_instructions = &.{
                        .{ .def_cfa = .{ .reg = Register.rsp.dwarfNum(), .off = 8 } },
                        .{ .offset = .{ .reg = Register.rip.dwarfNum(), .off = -8 } },
                    },
                };
            } else .{
                .code_alignment_factor = undefined,
                .data_alignment_factor = undefined,
                .return_address_register = undefined,
                .initial_instructions = &.{},
            },
        },
        .debug_info = .{},
        .debug_line = .{
            .header = switch (target.cpu.arch) {
                .x86_64, .aarch64 => .{
                    .minimum_instruction_length = 1,
                    .maximum_operations_per_instruction = 1,
                    .default_is_stmt = true,
                    .line_base = -5,
                    .line_range = 14,
                    .opcode_base = DW.LNS.set_isa + 1,
                },
                else => .{
                    .minimum_instruction_length = 1,
                    .maximum_operations_per_instruction = 1,
                    .default_is_stmt = true,
                    .line_base = 0,
                    .line_range = 1,
                    .opcode_base = DW.LNS.set_isa + 1,
                },
            },
        },
        .debug_line_str = .{
            .ni = .none,
            .offset = 0,
            .map = .empty,
        },
        .debug_str = .{
            .ni = .none,
            .offset = 0,
            .map = .empty,
        },
        .debug_str_offsets = .{
            .ni = .none,
            .offset = 0,
        },
    };
}

pub fn deinit(dwarf: *Dwarf) void {
    const gpa = dwarf.lf.comp.gpa;
    dwarf.const_pool.deinit(gpa);
    dwarf.units.deinit(gpa);
    dwarf.values.deinit(gpa);
    dwarf.globals.deinit(gpa);
    dwarf.funcs.deinit(gpa);
    dwarf.debug_str.map.deinit(gpa);
    dwarf.* = undefined;
}

pub fn initUnits(dwarf: *Dwarf, zcu: *Zcu) std.mem.Allocator.Error!void {
    try dwarf.units.ensureTotalCapacity(zcu.gpa, zcu.module_roots.count());
    for (zcu.module_roots.keys(), zcu.module_roots.values()) |mod, root| switch (root) {
        .none => {},
        else => dwarf.units.putAssumeCapacityNoClobber(mod, .{
            .frame_ni = .none,
            .cie_ni = .none,
            .debug_info_ni = .none,
            .debug_info_header_ni = .none,
            .debug_line_ni = .none,
            .debug_line_header_ni = .none,
        }),
    };
}

fn getNavNode(dwarf: *Dwarf, nav_index: InternPool.Nav.Index) link.Error!MappedFile.Node.Index {
    if (true) @panic("TODO");
    const zcu = dwarf.linkFile().comp.zcu.?;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    const unit = try dwarf.getUnit(zcu.fileByIndex(nav.srcInst(ip).resolveFile(ip)).mod.?);
    const gop = try dwarf.navs.getOrPut(dwarf.gpa, nav_index);
    if (gop.found_existing) return .{ unit, gop.value_ptr.* };
    const entry = try dwarf.addCommonEntry(unit);
    gop.value_ptr.* = entry;
    return .{ unit, entry };
}

pub fn getUnit(dwarf: *Dwarf, mod: *Module) Unit.Index {
    return @fromBackingInt(@intCast(dwarf.units.getIndex(mod).?));
}

pub fn getFunc(dwarf: *Dwarf, owner_nav: InternPool.Nav.Index) std.mem.Allocator.Error!Func.Index {
    const func_gop = try dwarf.funcs.getOrPut(dwarf.lf.comp.gpa, owner_nav);
    if (!func_gop.found_existing) func_gop.value_ptr.* = .{
        .fde_ni = .none,
        .debug_info_ni = .none,
        .debug_line_ni = .none,
    };
    return @fromBackingInt(@intCast(func_gop.index));
}

pub fn unitLengthSize(dwarf: *Dwarf) usize {
    return switch (dwarf.format) {
        .@"32" => 4,
        .@"64" => 12,
    };
}
pub fn genUnitLength(dwarf: *Dwarf, w: *Writer) Writer.Error!void {
    switch (dwarf.format) {
        .@"32" => try w.writeInt(u32, undefined, dwarf.endian),
        .@"64" => {
            try w.writeInt(u32, std.math.maxInt(u32), dwarf.endian);
            try w.writeInt(u64, undefined, dwarf.endian);
        },
    }
}
pub fn updateUnitLength(dwarf: *Dwarf, header: []u8, unit_length: u64) void {
    switch (dwarf.format) {
        .@"32" => std.mem.writeInt(u32, header[0..4], @intCast(unit_length - 4), dwarf.endian),
        .@"64" => std.mem.writeInt(u64, header[4..12], unit_length - 12, dwarf.endian),
    }
}

pub fn genUnitPadding(dwarf: *Dwarf, w: *Writer) Writer.Error!void {
    try dwarf.genUnitLength(w);
    try w.writeInt(u16, 0, dwarf.endian);
}

pub const EhFrameHdr = extern struct {
    version: u8,
    eh_frame_ptr_enc: std.dwarf.EH.PE,
    fde_count_enc: std.dwarf.EH.PE,
    table_enc: std.dwarf.EH.PE,
    eh_frame_ptr: u32,
};
pub fn genEhFrameHdr(
    dwarf: *Dwarf,
    eh_frame_hdr_ai: link.File.AtomId,
    eh_frame_hdr: *EhFrameHdr,
    eh_frame_si: link.File.SymbolId,
) link.Error!void {
    eh_frame_hdr.* = .{
        .version = 1,
        .eh_frame_ptr_enc = .{ .type = .sdata4, .rel = .pcrel },
        .fde_count_enc = .omit,
        .table_enc = .omit,
        .eh_frame_ptr = undefined,
    };
    const elf = dwarf.lf.cast(.elf2).?;
    try elf.addReloc(
        eh_frame_hdr_ai,
        @offsetOf(EhFrameHdr, "eh_frame_ptr"),
        eh_frame_si,
        0,
        .rel32(elf),
    );
}

pub fn genDebugFrameCie(
    dwarf: *Dwarf,
    dfw: *Writer,
    /// `null` means to generate an architecture-agnostic padding cie
    arch: ?std.Target.Cpu.Arch,
    format: Frame.Format,
) Writer.Error!void {
    try dwarf.genUnitLength(dfw);
    switch (format) {
        .eh_frame => try dfw.writeInt(u32, 0, dwarf.endian),
        .debug_frame => switch (dwarf.format) {
            .@"32" => try dfw.writeInt(u32, std.math.maxInt(u32), dwarf.endian),
            .@"64" => try dfw.writeInt(u64, std.math.maxInt(u64), dwarf.endian),
        },
    }
    try dfw.writeByte(if (arch) |_| switch (format) {
        .eh_frame => 1,
        .debug_frame => 4,
    } else 0);
    switch (arch orelse return) {
        else => unreachable,
        .x86_64 => {
            dev.check(.x86_64_backend);
            const Register = @import("../codegen/x86_64/bits.zig").Register;
            switch (format) {
                .eh_frame => try dfw.writeAll("zR\x00"),
                .debug_frame => {
                    try dfw.writeAll("\x00");
                    try dfw.writeByte(@backingInt(dwarf.address_size));
                    try dfw.writeByte(0);
                },
            }
            try dfw.writeUleb128(dwarf.frame.header.code_alignment_factor);
            try dfw.writeSleb128(dwarf.frame.header.data_alignment_factor);
            switch (format) {
                .eh_frame => try dfw.writeByte(@intCast(dwarf.frame.header.return_address_register)),
                .debug_frame => try dfw.writeUleb128(dwarf.frame.header.return_address_register),
            }
            switch (format) {
                .eh_frame => {
                    try dfw.writeUleb128(1);
                    try dfw.writeByte(@bitCast(@as(DW.EH.PE, .{ .type = .sdata4, .rel = .pcrel })));
                },
                .debug_frame => {},
            }
            try dfw.writeByte(DW.CFA.def_cfa_sf);
            try dfw.writeUleb128(Register.rsp.dwarfNum());
            try dfw.writeSleb128(-1);
            try dfw.writeByte(@as(u8, DW.CFA.offset) + Register.rip.dwarfNum());
            try dfw.writeUleb128(1);
        },
    }
    @memset(dfw.unusedCapacitySlice(), DW.CFA.nop);
}

pub fn updateEhFrameFde(dwarf: *Dwarf, fde: []u8, fde_offset: u64) void {
    const cie_pointer_offset = dwarf.unitLengthSize();
    std.mem.writeInt(
        u32,
        fde[cie_pointer_offset..][0..4],
        @intCast(fde_offset + cie_pointer_offset),
        dwarf.endian,
    );
}

pub fn genDebugInfoHeader(
    dwarf: *Dwarf,
    nw: *MappedFile.Node.Writer,
    unit: Unit.Index,
    zcu: *Zcu,
) link.EmitError!void {
    const comp = zcu.comp;
    const mod = unit.mod(dwarf);
    const diw = &nw.interface;
    try dwarf.genUnitLength(diw);
    try diw.writeInt(u16, 5, dwarf.endian);
    try diw.writeByte(DW.UT.compile);
    try diw.writeByte(@backingInt(dwarf.address_size));
    try dwarf.sectionOffset(nw, dwarf.debug_abbrev.ni.unwrap().?, 0);
    const compile_unit_offset = diw.end;
    try diw.writeUleb128(try dwarf.refAbbrevCode(.compile_unit));
    try dwarf.strp(&dwarf.debug_str, nw, "zig " ++ @import("build_options").version);
    try diw.writeByte(DW.LANG.Zig);
    const root_dir_path = try mod.root.toAbsolute(&comp.dirs, comp.gpa);
    defer comp.gpa.free(root_dir_path);
    try dwarf.strp(&dwarf.debug_line_str, nw, root_dir_path);
    try dwarf.strp(&dwarf.debug_line_str, nw, mod.root_src_path);
    try dwarf.sectionOffset(
        nw,
        dwarf.getUnit(comp.root_mod).get(dwarf).debug_info_header_ni.unwrap().?,
        compile_unit_offset,
    );
    try dwarf.sectionOffset(nw, unit.get(dwarf).debug_line_header_ni.unwrap().?, 0);
    const module_offset = diw.end;
    try diw.writeUleb128(try dwarf.refAbbrevCode(.module));
    try dwarf.strp(&dwarf.debug_str, nw, mod.fully_qualified_name);
    for ([_][]const u8{ "builtin", "root", "std" }, [_]*Module{
        zcu.builtin_modules.get(mod.getBuiltinOptions(comp.config).hash()).?,
        zcu.root_mod,
        zcu.std_mod,
    }) |name, dep| try dwarf.genModuleDependency(nw, name, dep, module_offset);
    for (mod.deps.keys(), mod.deps.values()) |name, dep|
        try dwarf.genModuleDependency(nw, name, dep, module_offset);
    for ([2]AbbrevCode{ .pad_1, .pad_n }) |pad| _ = try dwarf.refAbbrevCode(pad);
    try dwarf.genDebugInfoPadding(diw, diw.unusedCapacityLen());
}

fn genModuleDependency(
    dwarf: *Dwarf,
    nw: *MappedFile.Node.Writer,
    name: []const u8,
    dep: *Module,
    module_offset: usize,
) link.EmitError!void {
    const diw = &nw.interface;
    try diw.writeUleb128(try dwarf.refAbbrevCode(.module_dependency));
    try diw.writeAll(name);
    try diw.writeByte(0);
    try dwarf.sectionOffset(
        nw,
        dwarf.getUnit(dep).get(dwarf).debug_info_header_ni.unwrap().?,
        module_offset,
    );
}

pub fn genDebugInfoPadding(dwarf: *Dwarf, diw: *Writer, size: u64) Writer.Error!void {
    switch (size) {
        0 => {},
        1 => try diw.writeUleb128(dwarf.refAbbrevCodeIfExists(.pad_1).?),
        else => {
            const abbrev_code_offset = diw.end;
            try diw.writeUleb128(dwarf.refAbbrevCodeIfExists(.pad_n).?);
            const abbrev_code_size = diw.end - abbrev_code_offset;
            var block_len_size: u5 = 1;
            while (true) switch (std.math.order(size - abbrev_code_size - block_len_size, @as(u64, 1) << 7 * block_len_size)) {
                .lt => break try diw.writeUleb128(size - abbrev_code_size - block_len_size),
                .eq => {
                    // no length will ever work, so undercount and futz with the leb encoding to make up the missing byte
                    block_len_size += 1;
                    std.leb.writeUnsignedExtended(try diw.writableSlice(block_len_size), size - abbrev_code_size - block_len_size);
                    break;
                },
                .gt => block_len_size += 1,
            };
        },
    }
}

pub fn genDebugLineHeader(dwarf: *Dwarf, dlw: *Writer) Writer.Error!void {
    try dwarf.genUnitLength(dlw);
    @memset(dlw.unusedCapacitySlice(), 0xaa);
}

pub fn genDebugLinePadding(dlw: *Writer, size: u64) Writer.Error!void {
    switch (size) {
        0 => {},
        1 => try dlw.writeByte(DW.LNS.const_add_pc),
        else => {
            const extended_op_offset = dlw.end;
            try dlw.writeByte(DW.LNS.extended_op);
            const extended_op_size = dlw.end - extended_op_offset;
            var op_len_size: u5 = 1;
            while (true) switch (std.math.order(size - extended_op_size - op_len_size, @as(u64, 1) << 7 * op_len_size)) {
                .lt => break try dlw.writeUleb128(size - extended_op_size - op_len_size),
                .eq => {
                    // no length will ever work, so undercount and futz with the leb encoding to make up the missing byte
                    op_len_size += 1;
                    std.leb.writeUnsignedExtended(try dlw.writableSlice(op_len_size), size - extended_op_size - op_len_size);
                    break;
                },
                .gt => op_len_size += 1,
            };
        },
    }
}

fn refAbbrevCodeIfExists(
    dwarf: *Dwarf,
    abbrev_code: AbbrevCode,
) ?@typeInfo(AbbrevCode).@"enum".tag_type {
    assert(abbrev_code != .null);
    return if (dwarf.debug_abbrev.set.contains(abbrev_code)) @backingInt(abbrev_code) else null;
}

fn refAbbrevCode(
    dwarf: *Dwarf,
    abbrev_code: AbbrevCode,
) link.EmitError!@typeInfo(AbbrevCode).@"enum".tag_type {
    if (dwarf.refAbbrevCodeIfExists(abbrev_code)) |backing_int| {
        @branchHint(.likely);
        return backing_int;
    }
    const elf = dwarf.lf.cast(.elf2).?;
    var nw: MappedFile.Node.Writer = undefined;
    dwarf.debug_abbrev.ni.unwrap().?.writer(&elf.mf, elf.base.comp.gpa, &nw);
    defer nw.deinit();
    const abbrev = AbbrevCode.abbrevs.get(abbrev_code);
    const daw = &nw.interface;
    daw.end = dwarf.debug_abbrev.offset;
    try daw.writeUleb128(@backingInt(abbrev_code));
    try daw.writeUleb128(@backingInt(abbrev.tag));
    try daw.writeByte(if (abbrev.children) DW.CHILDREN.yes else DW.CHILDREN.no);
    for (abbrev.attrs) |*attr| inline for (attr) |info| try daw.writeUleb128(@backingInt(info));
    for (0..2) |_| try daw.writeUleb128(0);
    dwarf.debug_abbrev.offset = daw.end;
    dwarf.debug_abbrev.set.insert(abbrev_code);
    return dwarf.refAbbrevCodeIfExists(abbrev_code).?;
}

fn sectionOffset(
    dwarf: *Dwarf,
    nw: *MappedFile.Node.Writer,
    target_ni: MappedFile.Node.Index,
    addend: usize,
) link.EmitError!void {
    const offset = nw.interface.end;
    switch (dwarf.format) {
        .@"32" => try nw.interface.writeInt(u32, 0, dwarf.endian),
        .@"64" => try nw.interface.writeInt(u64, 0, dwarf.endian),
    }
    try dwarf.lf.cast(.elf2).?.addNodeReloc(
        nw.ni,
        offset,
        target_ni,
        @bitCast(@as(u64, addend)),
        switch (dwarf.format) {
            .@"32" => .abs32,
            .@"64" => .abs64,
        },
    );
}

fn strp(dwarf: *Dwarf, s: *String, nw: *MappedFile.Node.Writer, str: []const u8) link.EmitError!void {
    const comp = dwarf.lf.comp;
    const mf = &dwarf.lf.cast(.elf2).?.mf;
    try dwarf.sectionOffset(nw, s.ni.unwrap().?, s.get(comp.gpa, mf, str) catch |err| switch (err) {
        error.MappedFileIo => return comp.link_diags.fail("failed to write output file: {t}", .{
            mf.io_err.?,
        }),
        else => |e| return e,
    });
}

fn DeclValEnum(comptime T: type) type {
    const decl_names = @typeInfo(T).@"struct".decl_names;
    @setEvalBranchQuota(10 * decl_names.len);
    var field_names: [decl_names.len][]const u8 = undefined;
    var fields_len = 0;
    var min_value: ?comptime_int = null;
    var max_value: ?comptime_int = null;
    for (decl_names) |decl_name| {
        if (std.mem.startsWith(u8, decl_name, "HP_") or std.mem.endsWith(u8, decl_name, "_user")) continue;
        const value = @field(T, decl_name);
        field_names[fields_len] = decl_name;
        fields_len += 1;
        if (min_value == null or min_value.? > value) min_value = value;
        if (max_value == null or max_value.? < value) max_value = value;
    }
    if (fields_len == 0) return enum {};
    const TagInt = std.math.IntFittingRange(min_value orelse 0, max_value orelse 0);
    var field_vals: [fields_len]TagInt = undefined;
    for (field_names[0..fields_len], &field_vals) |name, *val| val.* = @field(T, name);
    return @Enum(TagInt, .exhaustive, field_names[0..fields_len], &field_vals);
}

pub const AbbrevCode = enum {
    null,
    // padding codes must be one byte uleb128 values to function
    pad_1,
    pad_n,
    // decl, generic decl, and instance codes are assumed to all have the same uleb128 length
    decl_alias,
    decl_empty_enum,
    decl_enum,
    decl_namespace_struct,
    decl_struct,
    decl_packed_struct,
    decl_union,
    decl_packed_union,
    decl_var,
    decl_const,
    decl_const_runtime_bits,
    decl_const_comptime_state,
    decl_const_runtime_bits_comptime_state,
    decl_nullary_func,
    decl_func,
    decl_nullary_func_generic,
    decl_func_generic,
    decl_extern_nullary_func,
    decl_extern_func,
    generic_decl_var,
    generic_decl_const,
    generic_decl_func,
    decl_instance_alias,
    decl_instance_empty_enum,
    decl_instance_enum,
    decl_instance_namespace_struct,
    decl_instance_struct,
    decl_instance_packed_struct,
    decl_instance_union,
    decl_instance_packed_union,
    decl_instance_var,
    decl_instance_const,
    decl_instance_const_runtime_bits,
    decl_instance_const_comptime_state,
    decl_instance_const_runtime_bits_comptime_state,
    decl_instance_nullary_func,
    decl_instance_func,
    decl_instance_nullary_func_generic,
    decl_instance_func_generic,
    decl_instance_extern_nullary_func,
    decl_instance_extern_func,
    // the rest are unrestricted other than empty variants must not be longer
    // than the non-empty variant, and so should appear first
    compile_unit,
    module,
    module_dependency,
    empty_file,
    file,
    access,
    enum_field,
    generated_field,
    field,
    field_default_runtime_bits,
    field_default_comptime_state,
    field_comptime,
    field_comptime_runtime_bits,
    field_comptime_comptime_state,
    packed_field,
    tagged_union,
    tagged_union_field,
    tagged_union_default_field,
    void_type,
    numeric_type,
    inferred_error_set_type,
    ptr_type,
    ptr_sentinel_type,
    ptr_aligned_type,
    ptr_aligned_sentinel_type,
    is_const,
    is_volatile,
    array_type,
    array_sentinel_type,
    vector_type,
    array_index,
    array_len,
    nullary_func_type,
    func_type,
    func_type_param,
    is_var_args,
    generated_empty_enum_type,
    generated_enum_type,
    generated_empty_struct_type,
    generated_struct_type,
    generated_union_type,
    empty_enum_type,
    enum_type,
    empty_struct_type,
    struct_type,
    empty_packed_struct_type,
    packed_struct_type,
    empty_union_type,
    union_type,
    empty_packed_union_type,
    packed_union_type,
    builtin_extern_nullary_func,
    builtin_extern_func,
    builtin_extern_var,
    empty_block,
    block,
    empty_inlined_func,
    inlined_func,
    arg,
    unnamed_arg,
    comptime_arg,
    unnamed_comptime_arg,
    comptime_arg_runtime_bits,
    unnamed_comptime_arg_runtime_bits,
    comptime_arg_comptime_state,
    unnamed_comptime_arg_comptime_state,
    comptime_arg_runtime_bits_comptime_state,
    unnamed_comptime_arg_runtime_bits_comptime_state,
    extern_param,
    local_var,
    local_const,
    local_const_runtime_bits,
    local_const_comptime_state,
    local_const_runtime_bits_comptime_state,
    undefined_comptime_value,
    comptime_value,
    location_comptime_value,
    aggregate_undefined_comptime_value,
    aggregate_comptime_value,
    aggregate_location_comptime_value,
    comptime_value_field_runtime_bits,
    comptime_value_field_comptime_state,
    comptime_value_elem_runtime_bits,
    comptime_value_elem_comptime_state,

    const decl_bytes = uleb128Bytes(@backingInt(AbbrevCode.decl_instance_extern_func));
    comptime {
        assert(uleb128Bytes(@backingInt(AbbrevCode.pad_1)) == 1);
        assert(uleb128Bytes(@backingInt(AbbrevCode.pad_n)) == 1);
        assert(uleb128Bytes(@backingInt(AbbrevCode.decl_alias)) == decl_bytes);
    }

    const Attr = struct {
        DeclValEnum(DW.AT),
        DeclValEnum(DW.FORM),
    };
    const decl_abbrev_common_attrs = &[_]Attr{
        .{ .ZIG_parent, .ref_addr },
        .{ .decl_line, .data4 },
        .{ .decl_column, .udata },
        .{ .accessibility, .data1 },
        .{ .name, .strp },
    };
    const generic_decl_abbrev_common_attrs = decl_abbrev_common_attrs ++ &[_]Attr{
        .{ .declaration, .flag_present },
    };
    const decl_instance_abbrev_common_attrs = &[_]Attr{
        .{ .ZIG_parent, .ref_addr },
        .{ .abstract_origin, .ref_addr },
    };
    const abbrevs = std.EnumArray(AbbrevCode, struct {
        tag: DeclValEnum(DW.TAG),
        children: bool = false,
        attrs: []const Attr = &.{},
    }).init(.{
        .pad_1 = .{
            .tag = .ZIG_padding,
        },
        .pad_n = .{
            .tag = .ZIG_padding,
            .attrs = &.{
                .{ .ZIG_padding, .block },
            },
        },
        .decl_alias = .{
            .tag = .imported_declaration,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .import, .ref_addr },
            },
        },
        .decl_empty_enum = .{
            .tag = .enumeration_type,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_enum = .{
            .tag = .enumeration_type,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_namespace_struct = .{
            .tag = .structure_type,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .declaration, .flag },
            },
        },
        .decl_struct = .{
            .tag = .structure_type,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .decl_packed_struct = .{
            .tag = .structure_type,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_union = .{
            .tag = .union_type,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .decl_packed_union = .{
            .tag = .union_type,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_var = .{
            .tag = .variable,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
                .{ .alignment, .udata },
                .{ .external, .flag },
            },
        },
        .decl_const = .{
            .tag = .constant,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
            },
        },
        .decl_const_runtime_bits = .{
            .tag = .constant,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .const_value, .block },
            },
        },
        .decl_const_comptime_state = .{
            .tag = .constant,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .decl_const_runtime_bits_comptime_state = .{
            .tag = .constant,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .const_value, .block },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .decl_nullary_func = .{
            .tag = .subprogram,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .noreturn, .flag },
            },
        },
        .decl_func = .{
            .tag = .subprogram,
            .children = true,
            .attrs = decl_abbrev_common_attrs[4..] ++ .{
                .{ .linkage_name, .strp },
                //.{ .type, .ref_addr },
                //.{ .low_pc, .addr },
                //.{ .high_pc, .data4 },
                //.{ .alignment, .udata },
                //.{ .external, .flag },
                //.{ .noreturn, .flag },
            },
        },
        .decl_nullary_func_generic = .{
            .tag = .subprogram,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_func_generic = .{
            .tag = .subprogram,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_extern_nullary_func = .{
            .tag = .subprogram,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .external, .flag_present },
                .{ .noreturn, .flag },
            },
        },
        .decl_extern_func = .{
            .tag = .subprogram,
            .children = true,
            .attrs = decl_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .external, .flag_present },
                .{ .noreturn, .flag },
            },
        },
        .generic_decl_var = .{
            .tag = .variable,
            .attrs = generic_decl_abbrev_common_attrs,
        },
        .generic_decl_const = .{
            .tag = .constant,
            .attrs = generic_decl_abbrev_common_attrs,
        },
        .generic_decl_func = .{
            .tag = .subprogram,
            .attrs = generic_decl_abbrev_common_attrs,
        },
        .decl_instance_alias = .{
            .tag = .imported_declaration,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .import, .ref_addr },
            },
        },
        .decl_instance_empty_enum = .{
            .tag = .enumeration_type,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_instance_enum = .{
            .tag = .enumeration_type,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_instance_namespace_struct = .{
            .tag = .structure_type,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .declaration, .flag },
            },
        },
        .decl_instance_struct = .{
            .tag = .structure_type,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .decl_instance_packed_struct = .{
            .tag = .structure_type,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_instance_union = .{
            .tag = .union_type,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .decl_instance_packed_union = .{
            .tag = .union_type,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_instance_var = .{
            .tag = .variable,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
                .{ .alignment, .udata },
                .{ .external, .flag },
            },
        },
        .decl_instance_const = .{
            .tag = .constant,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
            },
        },
        .decl_instance_const_runtime_bits = .{
            .tag = .constant,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .const_value, .block },
            },
        },
        .decl_instance_const_comptime_state = .{
            .tag = .constant,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .decl_instance_const_runtime_bits_comptime_state = .{
            .tag = .constant,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .const_value, .block },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .decl_instance_nullary_func = .{
            .tag = .subprogram,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .noreturn, .flag },
            },
        },
        .decl_instance_func = .{
            .tag = .subprogram,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
                .{ .alignment, .udata },
                .{ .external, .flag },
                .{ .noreturn, .flag },
            },
        },
        .decl_instance_nullary_func_generic = .{
            .tag = .subprogram,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_instance_func_generic = .{
            .tag = .subprogram,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .type, .ref_addr },
            },
        },
        .decl_instance_extern_nullary_func = .{
            .tag = .subprogram,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .external, .flag_present },
                .{ .noreturn, .flag },
            },
        },
        .decl_instance_extern_func = .{
            .tag = .subprogram,
            .children = true,
            .attrs = decl_instance_abbrev_common_attrs ++ .{
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .external, .flag_present },
                .{ .noreturn, .flag },
            },
        },
        .compile_unit = .{
            .tag = .compile_unit,
            .children = true,
            .attrs = &.{
                .{ .producer, .strp },
                .{ .language, .data1 },
                .{ .comp_dir, .line_strp },
                .{ .name, .line_strp },
                .{ .base_types, .ref_addr },
                .{ .stmt_list, .sec_offset },
                //.{ .rnglists_base, .sec_offset },
                //.{ .ranges, .rnglistx },
                .{ .use_UTF8, .flag_present },
            },
        },
        .module = .{
            .tag = .module,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                //.{ .ranges, .rnglistx },
            },
        },
        .module_dependency = .{
            .tag = .imported_module,
            .attrs = &.{
                .{ .name, .string },
                .{ .import, .ref_addr },
            },
        },
        .empty_file = .{
            .tag = .structure_type,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
            },
        },
        .file = .{
            .tag = .structure_type,
            .children = true,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .access = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
            },
        },
        .enum_field = .{
            .tag = .enumerator,
            .attrs = &.{
                .{ .const_value, .indirect },
                .{ .name, .strp },
            },
        },
        .generated_field = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .data_member_location, .udata },
                .{ .artificial, .flag_present },
            },
        },
        .field = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .data_member_location, .udata },
                .{ .alignment, .udata },
            },
        },
        .field_default_runtime_bits = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .data_member_location, .udata },
                .{ .alignment, .udata },
                .{ .default_value, .block },
            },
        },
        .field_default_comptime_state = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .data_member_location, .udata },
                .{ .alignment, .udata },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .field_comptime = .{
            .tag = .member,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .field_comptime_runtime_bits = .{
            .tag = .member,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
            },
        },
        .field_comptime_comptime_state = .{
            .tag = .member,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .packed_field = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .data_bit_offset, .udata },
            },
        },
        .tagged_union = .{
            .tag = .variant_part,
            .children = true,
            .attrs = &.{
                .{ .discr, .ref_addr },
            },
        },
        .tagged_union_field = .{
            .tag = .variant,
            .children = true,
            .attrs = &.{
                .{ .discr_value, .indirect },
            },
        },
        .tagged_union_default_field = .{
            .tag = .variant,
            .children = true,
        },
        .void_type = .{
            .tag = .unspecified_type,
            .attrs = &.{
                .{ .name, .strp },
            },
        },
        .numeric_type = .{
            .tag = .base_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .encoding, .data1 },
                .{ .bit_size, .udata },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .inferred_error_set_type = .{
            .tag = .typedef,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .ptr_type = .{
            .tag = .pointer_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .address_class, .data1 },
                .{ .type, .ref_addr },
            },
        },
        .ptr_sentinel_type = .{
            .tag = .pointer_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .ZIG_sentinel, .block },
                .{ .address_class, .data1 },
                .{ .type, .ref_addr },
            },
        },
        .ptr_aligned_type = .{
            .tag = .pointer_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .alignment, .udata },
                .{ .address_class, .data1 },
                .{ .type, .ref_addr },
            },
        },
        .ptr_aligned_sentinel_type = .{
            .tag = .pointer_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .ZIG_sentinel, .block },
                .{ .alignment, .udata },
                .{ .address_class, .data1 },
                .{ .type, .ref_addr },
            },
        },
        .is_const = .{
            .tag = .const_type,
            .attrs = &.{
                .{ .type, .ref_addr },
            },
        },
        .is_volatile = .{
            .tag = .volatile_type,
            .attrs = &.{
                .{ .type, .ref_addr },
            },
        },
        .array_type = .{
            .tag = .array_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .array_sentinel_type = .{
            .tag = .array_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .ZIG_sentinel, .block },
                .{ .type, .ref_addr },
            },
        },
        .vector_type = .{
            .tag = .array_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .GNU_vector, .flag_present },
            },
        },
        .array_index = .{
            .tag = .subrange_type,
            .attrs = &.{
                .{ .lower_bound, .udata },
            },
        },
        .array_len = .{
            .tag = .subrange_type,
            .attrs = &.{
                .{ .type, .ref_addr },
                .{ .count, .udata },
            },
        },
        .nullary_func_type = .{
            .tag = .subroutine_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .calling_convention, .data1 },
                .{ .type, .ref_addr },
            },
        },
        .func_type = .{
            .tag = .subroutine_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .calling_convention, .data1 },
                .{ .type, .ref_addr },
            },
        },
        .func_type_param = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .type, .ref_addr },
            },
        },
        .is_var_args = .{
            .tag = .unspecified_parameters,
        },
        .generated_empty_enum_type = .{
            .tag = .enumeration_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .generated_enum_type = .{
            .tag = .enumeration_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .generated_empty_struct_type = .{
            .tag = .structure_type,
            .attrs = &.{
                .{ .name, .strp },
                .{ .declaration, .flag },
            },
        },
        .generated_struct_type = .{
            .tag = .structure_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .generated_union_type = .{
            .tag = .union_type,
            .children = true,
            .attrs = &.{
                .{ .name, .strp },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .empty_enum_type = .{
            .tag = .enumeration_type,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .enum_type = .{
            .tag = .enumeration_type,
            .children = true,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .empty_struct_type = .{
            .tag = .structure_type,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .declaration, .flag },
            },
        },
        .struct_type = .{
            .tag = .structure_type,
            .children = true,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .empty_packed_struct_type = .{
            .tag = .structure_type,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .packed_struct_type = .{
            .tag = .structure_type,
            .children = true,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .empty_union_type = .{
            .tag = .union_type,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .union_type = .{
            .tag = .union_type,
            .children = true,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .byte_size, .udata },
                .{ .alignment, .udata },
            },
        },
        .empty_packed_union_type = .{
            .tag = .union_type,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .packed_union_type = .{
            .tag = .union_type,
            .children = true,
            .attrs = &.{
                .{ .decl_file, .udata },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .builtin_extern_nullary_func = .{
            .tag = .subprogram,
            .attrs = &.{
                .{ .ZIG_parent, .ref_addr },
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .external, .flag_present },
                .{ .noreturn, .flag },
            },
        },
        .builtin_extern_func = .{
            .tag = .subprogram,
            .children = true,
            .attrs = &.{
                .{ .ZIG_parent, .ref_addr },
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .low_pc, .addr },
                .{ .external, .flag_present },
                .{ .noreturn, .flag },
            },
        },
        .builtin_extern_var = .{
            .tag = .variable,
            .attrs = &.{
                .{ .ZIG_parent, .ref_addr },
                .{ .linkage_name, .strp },
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
                .{ .external, .flag_present },
            },
        },
        .empty_block = .{
            .tag = .lexical_block,
            .attrs = &.{
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
            },
        },
        .block = .{
            .tag = .lexical_block,
            .children = true,
            .attrs = &.{
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
            },
        },
        .empty_inlined_func = .{
            .tag = .inlined_subroutine,
            .attrs = &.{
                .{ .abstract_origin, .ref_addr },
                .{ .call_line, .udata },
                .{ .call_column, .udata },
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
            },
        },
        .inlined_func = .{
            .tag = .inlined_subroutine,
            .children = true,
            .attrs = &.{
                .{ .abstract_origin, .ref_addr },
                .{ .call_line, .udata },
                .{ .call_column, .udata },
                .{ .low_pc, .addr },
                .{ .high_pc, .data4 },
            },
        },
        .arg = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
            },
        },
        .unnamed_arg = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
            },
        },
        .comptime_arg = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .unnamed_comptime_arg = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .type, .ref_addr },
            },
        },
        .comptime_arg_runtime_bits = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
            },
        },
        .unnamed_comptime_arg_runtime_bits = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
            },
        },
        .comptime_arg_comptime_state = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .unnamed_comptime_arg_comptime_state = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .type, .ref_addr },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .comptime_arg_runtime_bits_comptime_state = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .unnamed_comptime_arg_runtime_bits_comptime_state = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .const_expr, .flag_present },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .extern_param = .{
            .tag = .formal_parameter,
            .attrs = &.{
                .{ .type, .ref_addr },
            },
        },
        .local_var = .{
            .tag = .variable,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
            },
        },
        .local_const = .{
            .tag = .constant,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
            },
        },
        .local_const_runtime_bits = .{
            .tag = .constant,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
            },
        },
        .local_const_comptime_state = .{
            .tag = .constant,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .local_const_runtime_bits_comptime_state = .{
            .tag = .constant,
            .attrs = &.{
                .{ .name, .strp },
                .{ .type, .ref_addr },
                .{ .const_value, .block },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .undefined_comptime_value = .{
            .tag = .ZIG_comptime_value,
            .attrs = &.{
                .{ .type, .ref_addr },
            },
        },
        .aggregate_undefined_comptime_value = .{
            .tag = .ZIG_comptime_value,
            .children = true,
            .attrs = &.{
                .{ .type, .ref_addr },
            },
        },
        .comptime_value = .{
            .tag = .ZIG_comptime_value,
            .attrs = &.{
                .{ .type, .ref_addr },
                .{ .const_value, .indirect },
            },
        },
        .aggregate_comptime_value = .{
            .tag = .ZIG_comptime_value,
            .children = true,
            .attrs = &.{
                .{ .type, .ref_addr },
                .{ .const_value, .indirect },
            },
        },
        .location_comptime_value = .{
            .tag = .ZIG_comptime_value,
            .attrs = &.{
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
            },
        },
        .aggregate_location_comptime_value = .{
            .tag = .ZIG_comptime_value,
            .children = true,
            .attrs = &.{
                .{ .type, .ref_addr },
                .{ .location, .exprloc },
            },
        },
        .comptime_value_field_runtime_bits = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .const_value, .block },
            },
        },
        .comptime_value_field_comptime_state = .{
            .tag = .member,
            .attrs = &.{
                .{ .name, .strp },
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .comptime_value_elem_runtime_bits = .{
            .tag = .member,
            .attrs = &.{
                .{ .const_value, .block },
            },
        },
        .comptime_value_elem_comptime_state = .{
            .tag = .member,
            .attrs = &.{
                .{ .ZIG_comptime_value, .ref_addr },
            },
        },
        .null = undefined,
    });
};

pub fn uleb128Bytes(value: anytype) u32 {
    var buf: [64]u8 = undefined;
    var dw: Writer.Discarding = .init(&buf);
    dw.writer.writeUleb128(value) catch unreachable;
    return @intCast(dw.fullCount());
}

pub fn sleb128Bytes(value: anytype) u32 {
    var buf: [64]u8 = undefined;
    var dw: Writer.Discarding = .init(&buf);
    dw.writer.writeSleb128(value) catch unreachable;
    return @intCast(dw.fullCount());
}

const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Compilation = @import("../Compilation.zig");
const dev = @import("../dev.zig");
const DW = std.dwarf;
const Dwarf = @This();
const InternPool = @import("../InternPool.zig");
const link = @import("../link.zig");
const MappedFile = @import("MappedFile.zig");
const Module = @import("../Module.zig");
const std = @import("std");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Writer = std.Io.Writer;
const Zcu = @import("../Zcu.zig");
