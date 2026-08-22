const Mir = @This();
const InternPool = @import("../../InternPool.zig");

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

instructions: std.MultiArrayList(Inst).Slice,

extra: []const u32,

pub const Inst = struct {
    tag: Tag,
    data: Data,

    /// The position of a given MIR isntruction with the instruction list.
    pub const Index = enum(u32) {
        _,
    };

    pub const Tag = enum(u8) {
        /// imm8
        set_page_i = 0x04,
        /// imm8
        set_addr_i = 0x09,
        /// imm8
        load_i_outa = 0x15,
        /// index
        jump = 0x68,
        /// nothing
        halt = 0xE3,
    };

    /// All instructions contain a 4-byte payload, which is contained within
    /// this union. `Tag` determines which union tag is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        imm8: u8,
        index: Index,
        nothing: void,

        comptime {
            switch (builtin.mode) {
                .Debug, .ReleaseSafe => {},
                .ReleaseFast, .ReleaseSmall => assert(@sizeOf(Data) == 4),
            }
        }
    };
};

pub fn deinit(mir: *Mir, gpa: std.mem.Allocator) void {
    mir.instructions.deinit(gpa);
    mir.* = undefined;
}

const AsmInstType = enum(u8) {
    SetPageReg, // Set the memory address high byte to a register value.
    SetPageI, // Set the memory address high byte to a constant value.
    SetAddrReg, // Set the memory address low byte to a register value.
    SetAddrI, // Set the memory address low byte to a constant value.
    Load, // Load a value from a constant address into a register.
    LoadI, // Load a constant value into a register.
    LoadP, // Load a value from a constant address (setting low byte only) into a register.
    LoadInc, // Load a value from the currently set memory address into a register, and increment the address n times.
    LoadStck, // Load a value from an offset on the current stack frame into a register.
    Store, // Store a value to a constant address from a register.
    StoreI, // Store a constant value into a constant address.
    StoreP, // Store a value to a constant address (low byte only) from a register.
    StoreInc, // Store a value from the currently set memory address from a register, and increment the address n times.
    StoreStck, // Store a value to an offset on the current stack frame, from a register.
    StoreNStck, // Store a value to an offset on the next stack frame, from a register.
    StorePStck, // Store a value to an offset on the previous stack frame, from a register.
    StoreStckI, // Store a constant value to an offset on the current stack frame.
    StoreNStckI, // Store a constant value to an offset on the next stack frame.
    StorePStckI, // Store a constant value to an offset on the previous stack frame.
    Copy, // Copy a value from one register to another register.
    Jump, // Jump to a constant location.
    JumpReg, // Jump to a register A (high byte) + register B (low byte).
    JumpMem, // Jump to a location pointed to by memory at the current memory address (high byte first).
    Call, // Call a function.
    Return, // Return from a function.
    CmpI, // Compare A to a constant value (sets flags, but discards result).
    CmpAndI, // Compare A to a constant value with bitwise AND (sets flags, but discards result).
    Cmp, // Compare A to a value from memory (sets flags, but discards result).
    CmpAnd, // Compare A to a value in memory with bitwise AND (sets flags, but discards result).
    CmpReg, // Compare A to a value from a register (sets flags, but discards result).
    CmpAndReg, // Compare A to a value from a register with bitwise AND (sets flags, but discards result).
    ShiftL, // Shift B left by 1.
    ShiftR, // Shift B right by 1.
    RotateL, // Rotate B left by 1.
    RotateR, // Rotate B right by 1.
    AddI, // Add a constant value to A.
    SubI, // Subtract a constant value from A.
    AndI, // Bitwise-AND A with a constant value.
    AddINF, // Add a constant value to A, without updating flags.
    SubINF, // Subtract a constant value from A, without updating flags.
    AndINF, // Bitwise-AND A with a constant value, without updating flags.
    AccumulateAdd, // Add register B to A -> A.
    AccumulateSub, // Subtract register B from A -> A.
    AccumulateAnd, // A & B -> A.
    OrI, // Bitwise OR B with A -> A.
    XorI, // Bitwise OR a constant value with A -> A.
    Not, // Invert register A.
    Add, // Add a value from memory to A.
    Sub, // Subtract a value from memory from A.
    And, // AND A with a value from memory.
    Or, // OR A with a value from memory.
    Xor, // XOR A with a value from memory.
    Nop, // No-op.
    Nop1, // No-op with 1 extra clock cycle.
    Nop2, // No-op with 2 extra clock cycles.
    Halt, // Halt - stop the program forever (until reset).
};

const Registers = enum(u8) {
    A,
    B,
    C,
    PCnt,
    MAdr,
    Stack,
    OutA,
    Shift,
    Swap,
};
