//! AArch64 interpreter. Register 31 is resolved per encoding,
//! and every W-register write clears the upper half of its X register.
const std = @import("std");
const Memory = @import("../memory/address_space.zig").Memory;

pub const Event = union(enum) { next, svc: u16, brk: u16 };

pub const Cpu = struct {
    x: [31]u64 = @splat(0),
    v: [32]u128 = @splat(0),
    sp: u64 = 0,
    pc: u64 = 0,
    last_pc: u64 = 0,
    last_instruction: u32 = 0,
    nzcv: u4 = 0,
    tpidrro_el0: u64 = 0,
    tpidr_el0: u64 = 0,
    fpcr: u32 = 0,
    fpsr: u32 = 0,
    counter: u64 = 0,
    counter_frequency: u32 = 19_200_000,
    exclusive_address: ?u64 = null,
    exclusive_size: u8 = 0,

    pub fn init(entry: u64, stack: u64) Cpu {
        return .{ .pc = entry, .sp = stack };
    }

    pub fn clearExclusive(self: *Cpu) void {
        self.exclusive_address = null;
    }

    pub fn step(self: *Cpu, memory: *Memory) !Event {
        if (self.pc & 3 != 0) return error.UnalignedInstruction;
        const instruction = try memory.fetch(self.pc);
        self.last_pc = self.pc;
        self.last_instruction = instruction;
        var next_pc = self.pc +% 4;
        const event = try self.execute(memory, instruction, &next_pc);
        self.pc = next_pc;
        self.counter +%= 1;
        return event;
    }

    fn reg(self: *const Cpu, index: u5, width: u7, use_sp: bool) u64 {
        const value = if (index == 31) (if (use_sp) self.sp else 0) else self.x[index];
        return value & mask(width);
    }

    fn setReg(self: *Cpu, index: u5, value: u64, width: u7, use_sp: bool) void {
        const result = value & mask(width);
        if (index == 31) {
            if (use_sp) self.sp = result;
        } else self.x[index] = result;
    }

    fn condition(self: *const Cpu, cond: u4) bool {
        const n = self.nzcv & 8 != 0;
        const z = self.nzcv & 4 != 0;
        const c = self.nzcv & 2 != 0;
        const v = self.nzcv & 1 != 0;
        var result = switch (@as(u3, @intCast(cond >> 1))) {
            0 => z,
            1 => c,
            2 => n,
            3 => v,
            4 => c and !z,
            5 => n == v,
            6 => n == v and !z,
            7 => true,
        };
        // Both AL and NV are unconditional in A64's ConditionHolds operation.
        if (cond & 1 != 0 and cond != 15) result = !result;
        return result;
    }

    fn add(self: *Cpu, lhs: u64, rhs: u64, carry: bool, width: u7, flags: bool) u64 {
        const m = mask(width);
        const a = lhs & m;
        const b = rhs & m;
        const sum: u128 = @as(u128, a) + @as(u128, b) + @intFromBool(carry);
        const result: u64 = @as(u64, @truncate(sum)) & m;
        if (flags) {
            const sign: u64 = @as(u64, 1) << @intCast(width - 1);
            self.nzcv = (@as(u4, @intFromBool(result & sign != 0)) << 3) |
                (@as(u4, @intFromBool(result == 0)) << 2) |
                (@as(u4, @intFromBool(sum > m)) << 1) |
                @as(u4, @intFromBool((~(a ^ b) & (a ^ result) & sign) != 0));
        }
        return result;
    }

    fn logicalFlags(self: *Cpu, result: u64, width: u7) void {
        self.nzcv = (@as(u4, @intFromBool(result & (@as(u64, 1) << @intCast(width - 1)) != 0)) << 3) |
            (@as(u4, @intFromBool(result & mask(width) == 0)) << 2);
    }

    fn execute(self: *Cpu, memory: *Memory, ins: u32, next_pc: *u64) !Event {
        const rd: u5 = @truncate(ins);
        const rn: u5 = @truncate(ins >> 5);
        const rm: u5 = @truncate(ins >> 16);
        const width: u7 = if (ins >> 31 != 0) 64 else 32;

        if (ins & 0xffe0001f == 0xd4000001) return .{ .svc = @truncate(ins >> 5) };
        if (ins & 0xffe0001f == 0xd4200000) return .{ .brk = @truncate(ins >> 5) };

        if (ins & 0x7c000000 == 0x14000000) {
            if (ins >> 31 != 0) self.x[30] = next_pc.*;
            next_pc.* = self.pc +% signedImmediate(ins & 0x03ffffff, 26) *% 4;
            return .next;
        }
        if (ins & 0xff000010 == 0x54000000) {
            if (self.condition(@truncate(ins))) next_pc.* = self.pc +% signedImmediate((ins >> 5) & 0x7ffff, 19) *% 4;
            return .next;
        }
        if (ins & 0x7e000000 == 0x34000000) {
            if ((self.reg(rd, width, false) == 0) != (ins & 0x01000000 != 0))
                next_pc.* = self.pc +% signedImmediate((ins >> 5) & 0x7ffff, 19) *% 4;
            return .next;
        }
        if (ins & 0x7e000000 == 0x36000000) {
            const bit: u6 = @intCast(((ins >> 31) << 5) | ((ins >> 19) & 31));
            if ((self.reg(rd, 64, false) & (@as(u64, 1) << bit) == 0) != (ins & 0x01000000 != 0))
                next_pc.* = self.pc +% signedImmediate((ins >> 5) & 0x3fff, 14) *% 4;
            return .next;
        }
        const branch_register = ins & 0xfffffc1f;
        if (branch_register == 0xd61f0000 or branch_register == 0xd63f0000 or branch_register == 0xd65f0000) {
            if (rn == 31) return error.UndefinedInstruction;
            const target = self.x[rn];
            if (branch_register == 0xd63f0000) self.x[30] = next_pc.*;
            next_pc.* = target;
            return .next;
        }

        if (ins & 0x1f000000 == 0x10000000) {
            const immediate = signedImmediate(((ins >> 5) & 0x7ffff) << 2 | ((ins >> 29) & 3), 21);
            const value = if (ins >> 31 != 0) (self.pc & ~@as(u64, 4095)) +% (immediate << 12) else self.pc +% immediate;
            self.setReg(rd, value, 64, false);
            return .next;
        }
        if (ins & 0x1f800000 == 0x12800000) {
            const opcode = (ins >> 29) & 3;
            const shift: u6 = @intCast(((ins >> 21) & 3) * 16);
            if (opcode == 1 or (width == 32 and shift >= 32)) return error.UndefinedInstruction;
            const immediate = @as(u64, (ins >> 5) & 0xffff) << shift;
            const value = switch (opcode) {
                0 => ~immediate,
                2 => immediate,
                3 => (self.reg(rd, width, false) & ~(@as(u64, 0xffff) << shift)) | immediate,
                else => unreachable,
            };
            self.setReg(rd, value, width, false);
            return .next;
        }
        if (ins & 0x1f800000 == 0x11000000) {
            const subtract = ins & 0x40000000 != 0;
            const flags = ins & 0x20000000 != 0;
            const immediate: u64 = @as(u64, (ins >> 10) & 0xfff) << @as(u6, if (ins & 0x00400000 != 0) 12 else 0);
            const result = self.add(self.reg(rn, width, true), if (subtract) ~immediate else immediate, subtract, width, flags);
            self.setReg(rd, result, width, !flags);
            return .next;
        }
        if (ins & 0x1f800000 == 0x12000000) {
            const n: u1 = @truncate(ins >> 22);
            if (width == 32 and n != 0) return error.UndefinedInstruction;
            const masks = try decodeBitMasks(n, @truncate(ins >> 10), @truncate(ins >> 16), width, true);
            const opcode = (ins >> 29) & 3;
            const lhs = self.reg(rn, width, false);
            const result = switch (opcode) {
                0, 3 => lhs & masks.write,
                1 => lhs | masks.write,
                2 => lhs ^ masks.write,
                else => unreachable,
            };
            if (opcode == 3) self.logicalFlags(result, width);
            self.setReg(rd, result, width, opcode != 3);
            return .next;
        }
        if (ins & 0x1f800000 == 0x13000000) {
            const n: u1 = @truncate(ins >> 22);
            const r: u6 = @truncate(ins >> 16);
            const s: u6 = @truncate(ins >> 10);
            const opcode = (ins >> 29) & 3;
            if (n != @intFromBool(width == 64) or opcode == 3 or (width == 32 and (r >= 32 or s >= 32))) return error.UndefinedInstruction;
            const masks = try decodeBitMasks(n, s, r, width, false);
            const source = self.reg(rn, width, false);
            const old = self.reg(rd, width, false);
            const rotated = rotateRight(source, r, width);
            const bottom = if (opcode == 1) (old & ~masks.write) | (rotated & masks.write) else rotated & masks.write;
            const top = if (opcode == 0 and source & (@as(u64, 1) << s) != 0) mask(width) else if (opcode == 1) old else 0;
            self.setReg(rd, (top & ~masks.top) | (bottom & masks.top), width, false);
            return .next;
        }
        if (ins & 0x1f800000 == 0x13800000) {
            const lsb: u6 = @truncate(ins >> 10);
            if (ins & 0x60200000 != 0 or ((ins >> 22) & 1) != @intFromBool(width == 64) or lsb >= width) return error.UndefinedInstruction;
            const value = if (lsb == 0) self.reg(rm, width, false) else (self.reg(rm, width, false) >> lsb) | (self.reg(rn, width, false) << @intCast(width - lsb));
            self.setReg(rd, value, width, false);
            return .next;
        }
        if (ins & 0x1f000000 == 0x0a000000) {
            const amount: u6 = @truncate(ins >> 10);
            if (amount >= width) return error.UndefinedInstruction;
            var rhs = shifted(self.reg(rm, width, false), @truncate(ins >> 22), amount, width);
            if (ins & 0x00200000 != 0) rhs = ~rhs;
            const opcode = (ins >> 29) & 3;
            const lhs = self.reg(rn, width, false);
            const result = switch (opcode) {
                0, 3 => lhs & rhs,
                1 => lhs | rhs,
                2 => lhs ^ rhs,
                else => unreachable,
            };
            if (opcode == 3) self.logicalFlags(result, width);
            self.setReg(rd, result, width, false);
            return .next;
        }
        if (ins & 0x1f000000 == 0x0b000000) {
            const subtract = ins & 0x40000000 != 0;
            const flags = ins & 0x20000000 != 0;
            const extended = ins & 0x00200000 != 0;
            var rhs: u64 = undefined;
            if (extended) {
                if (ins & 0x00c00000 != 0) return error.UndefinedInstruction;
                const amount: u3 = @truncate(ins >> 10);
                if (amount > 4) return error.UndefinedInstruction;
                rhs = extend(self.reg(rm, 64, false), @truncate(ins >> 13)) << amount;
            } else {
                const amount: u6 = @truncate(ins >> 10);
                const shift: u2 = @truncate(ins >> 22);
                if (amount >= width or shift == 3) return error.UndefinedInstruction;
                rhs = shifted(self.reg(rm, width, false), shift, amount, width);
            }
            const result = self.add(self.reg(rn, width, extended), if (subtract) ~rhs else rhs, subtract, width, flags);
            self.setReg(rd, result, width, extended and !flags);
            return .next;
        }
        if (ins & 0x1fe0fc00 == 0x1a000000) {
            const rhs = self.reg(rm, width, false);
            const result = self.add(self.reg(rn, width, false), if (ins & 0x40000000 != 0) ~rhs else rhs, self.nzcv & 2 != 0, width, ins & 0x20000000 != 0);
            self.setReg(rd, result, width, false);
            return .next;
        }
        if (ins & 0x1fe00000 == 0x1a400000) {
            if (ins & 0x20000410 != 0x20000000) return error.UndefinedInstruction;
            if (self.condition(@truncate(ins >> 12))) {
                const rhs = if (ins & 0x800 != 0) @as(u64, rm) else self.reg(rm, width, false);
                const subtract = ins & 0x40000000 != 0;
                _ = self.add(self.reg(rn, width, false), if (subtract) ~rhs else rhs, subtract, width, true);
            } else self.nzcv = @truncate(ins);
            return .next;
        }
        if (ins & 0x1fe00000 == 0x1a800000) {
            if (ins & 0x20000800 != 0) return error.UndefinedInstruction;
            var value = self.reg(rn, width, false);
            if (!self.condition(@truncate(ins >> 12))) {
                value = self.reg(rm, width, false);
                if (ins & 0x40000000 != 0) value = ~value;
                if (ins & 0x400 != 0) value +%= 1;
            }
            self.setReg(rd, value, width, false);
            return .next;
        }
        if (ins & 0x7fe00000 == 0x5ac00000) {
            if (rm != 0) return error.UndefinedInstruction;
            const source = self.reg(rn, width, false);
            const opcode = (ins >> 10) & 63;
            const value: u64 = switch (opcode) {
                0 => if (width == 64) @bitReverse(source) else @as(u64, @bitReverse(@as(u32, @truncate(source)))),
                1 => reverseGroups(source, width, 2),
                2 => reverseGroups(source, width, 4),
                3 => if (width == 64) @byteSwap(source) else return error.UndefinedInstruction,
                4 => if (width == 64) @clz(source) else @clz(@as(u32, @truncate(source))),
                5 => blk: {
                    const adjusted = if (source & (@as(u64, 1) << @intCast(width - 1)) != 0) ~source else source;
                    const zeros: u64 = if (width == 64) @clz(adjusted) else @clz(@as(u32, @truncate(adjusted)));
                    break :blk zeros - 1;
                },
                else => return error.UnsupportedInstruction,
            };
            self.setReg(rd, value, width, false);
            return .next;
        }
        if (ins & 0x1fe00000 == 0x1ac00000) {
            if (ins & 0x60000000 != 0) return error.UndefinedInstruction;
            const a = self.reg(rn, width, false);
            const b = self.reg(rm, width, false);
            const opcode = (ins >> 10) & 63;
            const amount: u6 = @intCast(b & (width - 1));
            const value = switch (opcode) {
                2 => if (b == 0) 0 else a / b,
                3 => signedDivide(a, b, width),
                8 => shifted(a, 0, amount, width),
                9 => shifted(a, 1, amount, width),
                10 => shifted(a, 2, amount, width),
                11 => shifted(a, 3, amount, width),
                else => return error.UnsupportedInstruction,
            };
            self.setReg(rd, value, width, false);
            return .next;
        }
        if (ins & 0x1f000000 == 0x1b000000) {
            const op = (ins >> 21) & 7;
            const ra: u5 = @truncate(ins >> 10);
            const subtract = ins & 0x8000 != 0;
            if (ins & 0x60000000 != 0) return error.UndefinedInstruction;
            var product: u64 = undefined;
            switch (op) {
                0 => product = self.reg(rn, width, false) *% self.reg(rm, width, false),
                1, 5 => {
                    if (width != 64) return error.UndefinedInstruction;
                    product = if (op == 1) signExtend(self.reg(rn, 32, false), 32) *% signExtend(self.reg(rm, 32, false), 32) else self.reg(rn, 32, false) *% self.reg(rm, 32, false);
                },
                2, 6 => {
                    if (width != 64 or ra != 31 or subtract) return error.UndefinedInstruction;
                    if (op == 2) {
                        const a: i64 = @bitCast(self.reg(rn, 64, false));
                        const b: i64 = @bitCast(self.reg(rm, 64, false));
                        const full: u128 = @bitCast(@as(i128, a) * @as(i128, b));
                        product = @truncate(full >> 64);
                    } else product = @truncate((@as(u128, self.reg(rn, 64, false)) * self.reg(rm, 64, false)) >> 64);
                    self.setReg(rd, product, width, false);
                    return .next;
                },
                else => return error.UndefinedInstruction,
            }
            const acc = self.reg(ra, width, false);
            self.setReg(rd, if (subtract) acc -% product else acc +% product, width, false);
            return .next;
        }

        if (try self.simd(memory, ins)) return .next;
        if (try self.floatingPoint(ins)) return .next;

        if (ins & 0x3b000000 == 0x18000000) {
            const address = self.pc +% signedImmediate((ins >> 5) & 0x7ffff, 19) *% 4;
            if (ins & 0x04000000 != 0) {
                const opc: u2 = @truncate(ins >> 30);
                if (opc == 3) return error.UndefinedInstruction;
                self.v[rd] = try readSized(memory, address, @as(u8, 4) << opc);
                return .next;
            }
            switch (ins >> 30) {
                0 => self.setReg(rd, try memory.readInt(u32, address), 32, false),
                1 => self.setReg(rd, try memory.readInt(u64, address), 64, false),
                2 => self.setReg(rd, signExtend(try memory.readInt(u32, address), 32), 64, false),
                3 => {}, // PRFM has no architecturally visible result.
                else => unreachable,
            }
            return .next;
        }
        if (ins & 0x3b000000 == 0x39000000) {
            const vector = ins & 0x04000000 != 0;
            const size: u2 = @truncate(ins >> 30);
            const opc: u2 = @truncate(ins >> 22);
            const bytes: u8 = if (vector and opc >= 2) 16 else @as(u8, 1) << size;
            const address = self.reg(rn, 64, true) +% (@as(u64, (ins >> 10) & 0xfff) * bytes);
            try self.transfer(memory, address, rd, size, opc, vector);
            return .next;
        }
        if (ins & 0x3b200000 == 0x38000000) {
            const mode: u2 = @truncate(ins >> 10);
            const writeback = mode == 1 or mode == 3;
            if (ins & 0xffc00000 == 0xf8800000 and mode != 0) return error.UndefinedInstruction;
            if (writeback and rd == rn and rn != 31 and ins & 0x04000000 == 0) return error.InvalidRegisterEncoding;
            const offset = signedImmediate((ins >> 12) & 0x1ff, 9);
            const base = self.reg(rn, 64, true);
            const address = if (mode == 1) base else base +% offset;
            try self.transfer(memory, address, rd, @truncate(ins >> 30), @truncate(ins >> 22), ins & 0x04000000 != 0);
            if (writeback) self.setReg(rn, base +% offset, 64, true);
            return .next;
        }
        if (ins & 0x3b200c00 == 0x38200800) {
            const option: u3 = @truncate(ins >> 13);
            if (option & 2 == 0) return error.UndefinedInstruction;
            const vector = ins & 0x04000000 != 0;
            const size: u2 = @truncate(ins >> 30);
            const opc: u2 = @truncate(ins >> 22);
            const shift: u3 = if (ins & 0x1000 == 0) 0 else if (vector and opc >= 2) 4 else size;
            const address = self.reg(rn, 64, true) +% (extend(self.reg(rm, 64, false), option) << shift);
            try self.transfer(memory, address, rd, size, opc, vector);
            return .next;
        }
        if (ins & 0x3a000000 == 0x28000000) {
            const vector = ins & 0x04000000 != 0;
            const opc: u2 = @truncate(ins >> 30);
            const load = ins & 0x00400000 != 0;
            if (opc == 3 or (!vector and (opc == 1 and !load))) return error.UndefinedInstruction;
            const bytes: u8 = if (vector) @as(u8, 4) << opc else if (opc == 2) 8 else 4;
            const rt2: u5 = @truncate(ins >> 10);
            const mode: u2 = @truncate(ins >> 23);
            if (!vector and opc == 1 and mode == 0) return error.UndefinedInstruction;
            const writeback = mode == 1 or mode == 3;
            if ((load and rd == rt2) or (!vector and writeback and rn != 31 and (rn == rd or rn == rt2))) return error.InvalidRegisterEncoding;
            const offset = signedImmediate((ins >> 15) & 0x7f, 7) *% bytes;
            const base = self.reg(rn, 64, true);
            const address = if (mode == 1) base else base +% offset;
            if (vector) {
                if (load) {
                    const first = try readSized(memory, address, bytes);
                    const second = try readSized(memory, address +% bytes, bytes);
                    self.v[rd] = first;
                    self.v[rt2] = second;
                } else {
                    try writeSized(memory, address, bytes, self.v[rd]);
                    try writeSized(memory, address +% bytes, bytes, self.v[rt2]);
                    self.clearExclusive();
                }
            } else if (load) {
                const first: u64 = @truncate(try readSized(memory, address, bytes));
                const second: u64 = @truncate(try readSized(memory, address +% bytes, bytes));
                const result_width: u7 = if (opc == 0) 32 else 64;
                self.setReg(rd, if (opc == 1) signExtend(first, 32) else first, result_width, false);
                self.setReg(rt2, if (opc == 1) signExtend(second, 32) else second, result_width, false);
            } else {
                try writeSized(memory, address, bytes, self.reg(rd, 64, false));
                try writeSized(memory, address +% bytes, bytes, self.reg(rt2, 64, false));
                self.clearExclusive();
            }
            if (writeback) self.setReg(rn, base +% offset, 64, true);
            return .next;
        }
        if (ins & 0x3f000000 == 0x08000000) {
            // A single guest thread owns the monitor; a scheduler must clear it
            // on context switches and writes by another guest execution agent.
            if (ins & 0x00200000 != 0) return error.UnsupportedInstruction;
            if (ins & 0x00007c00 != 0x00007c00) return error.UndefinedInstruction;
            const size: u2 = @truncate(ins >> 30);
            const bytes: u8 = @as(u8, 1) << size;
            const address = self.reg(rn, 64, true);
            if (address & (bytes - 1) != 0) return error.UnalignedExclusiveAccess;
            const load = ins & 0x00400000 != 0;
            const ordered = ins & 0x00800000 != 0;
            if ((load or ordered) and rm != 31) return error.UndefinedInstruction;
            if (ordered and ins & 0x00008000 == 0) return error.UndefinedInstruction;
            if (load) {
                self.setReg(rd, @truncate(try readSized(memory, address, bytes)), if (size == 3) 64 else 32, false);
                if (!ordered) {
                    self.exclusive_address = address;
                    self.exclusive_size = bytes;
                }
            } else if (ordered) {
                try writeSized(memory, address, bytes, self.reg(rd, 64, false));
                self.clearExclusive();
            } else {
                if (rm == rn or rm == rd) return error.InvalidRegisterEncoding;
                const success = self.exclusive_address == address and self.exclusive_size == bytes;
                if (success) try writeSized(memory, address, bytes, self.reg(rd, 64, false));
                self.setReg(rm, @intFromBool(!success), 32, false);
                self.clearExclusive();
            }
            return .next;
        }

        if (ins & 0xfffff01f == 0xd503301f) {
            switch ((ins >> 5) & 7) {
                2 => self.clearExclusive(), // CLREX
                4, 5 => {}, // DSB/DMB: guest memory is immediately coherent.
                6 => if ((ins >> 8) & 15 != 15) return error.UnsupportedInstruction, // ISB
                else => return error.UnsupportedInstruction,
            }
            return .next;
        }
        if (ins & 0xfffff01f == 0xd503201f) {
            if ((ins >> 5) & 0x7f > 5) return error.UnsupportedInstruction;
            return .next; // NOP, YIELD, WFE, WFI, SEV and SEVL.
        }
        if (ins & 0xfff00000 == 0xd5300000) {
            const value: u64 = switch (ins & 0xffffffe0) {
                0xd53bd040 => self.tpidr_el0,
                0xd53bd060 => self.tpidrro_el0,
                0xd53be000 => self.counter_frequency,
                0xd53be020, 0xd53be040 => self.counter,
                0xd53b4200 => @as(u64, self.nzcv) << 28,
                0xd53b4400 => self.fpcr,
                0xd53b4420 => self.fpsr,
                0xd53b0020 => 0x8444c004,
                0xd53b00e0 => 4, // DCZID_EL0: 64-byte DC ZVA blocks, permitted.
                else => return error.UnsupportedSystemRegister,
            };
            self.setReg(rd, value, 64, false);
            return .next;
        }
        if (ins & 0xfff00000 == 0xd5100000) {
            const value = self.reg(rd, 64, false);
            switch (ins & 0xffffffe0) {
                0xd51bd040 => self.tpidr_el0 = value,
                0xd51b4200 => self.nzcv = @truncate(value >> 28),
                0xd51b4400 => self.fpcr = @truncate(value),
                0xd51b4420 => self.fpsr = @truncate(value),
                else => return error.UnsupportedSystemRegister,
            }
            return .next;
        }
        if (ins & 0xffffffe0 == 0xd50b7420) {
            const zeros: [64]u8 = @splat(0);
            try memory.write(self.reg(rd, 64, false) & ~@as(u64, 63), &zeros);
            self.clearExclusive();
            return .next;
        }
        if (ins & 0xffffffe0 == 0xd50b7b20 or ins & 0xffffffe0 == 0xd50b7520 or
            ins & 0xffffffe0 == 0xd50b7a20 or ins & 0xffffffe0 == 0xd50b7e20) return .next;
        if (ins == 0 or ins == 0xffffffff) return error.UndefinedInstruction;
        return error.UnsupportedInstruction;
    }

    fn simd(self: *Cpu, memory: *Memory, ins: u32) !bool {
        const rd: u5 = @truncate(ins);
        const rn: u5 = @truncate(ins >> 5);
        const rm: u5 = @truncate(ins >> 16);
        const bytes: u8 = if (ins & 0x40000000 != 0) 16 else 8;
        const vector_mask: u128 = if (bytes == 16) std.math.maxInt(u128) else std.math.maxInt(u64);
        const logical = ins & 0xbfe0fc00;
        const a = self.v[rn];
        const b = self.v[rm];
        const old = self.v[rd];
        if (ins & 0xff80fc00 == 0x5f005400) {
            const immediate: u7 = @truncate(ins >> 16);
            if (immediate < 64) return error.UndefinedInstruction;
            self.v[rd] = @as(u64, @truncate(a)) << @as(u6, @intCast(immediate - 64));
            return true;
        }
        const result: ?u128 = switch (logical) {
            0x0e201c00 => a & b,
            0x0e601c00 => a & ~b,
            0x0ea01c00 => a | b,
            0x0ee01c00 => a | ~b,
            0x2e201c00 => a ^ b,
            0x2e601c00 => (old & a) | (~old & b),
            0x2ea01c00 => (old & ~b) | (a & b),
            0x2ee01c00 => (old & b) | (a & ~b),
            else => null,
        };
        if (result) |value| {
            self.v[rd] = value & vector_mask;
            return true;
        }
        const copy = ins & 0xbfe0fc00;
        if (copy == 0x0e000400 or copy == 0x0e000c00 or copy == 0x0e001c00 or copy == 0x0e002c00 or copy == 0x0e003c00 or ins & 0xffe0fc00 == 0x5e000400) {
            const imm5: u5 = @truncate(ins >> 16);
            if (imm5 == 0) return error.UndefinedInstruction;
            const scale: u3 = @intCast(@ctz(imm5));
            if (scale > 3) return error.UndefinedInstruction;
            const lane_bytes: u8 = @as(u8, 1) << scale;
            const index: u5 = @intCast(imm5 >> @intCast(scale + 1));
            if (ins & 0xffe0fc00 == 0x5e000400) {
                if (lane_bytes != 8) return error.UndefinedInstruction;
                self.v[rd] = vectorLane(a, index, lane_bytes);
            } else switch (copy) {
                0x0e000400 => {
                    if (lane_bytes == 8 and bytes != 16) return error.UndefinedInstruction;
                    self.v[rd] = replicate(vectorLane(a, index, lane_bytes), lane_bytes, bytes);
                },
                0x0e000c00 => {
                    if (index != 0 or lane_bytes > bytes / 2) return error.UndefinedInstruction;
                    self.v[rd] = replicate(self.reg(rn, 64, false), lane_bytes, bytes);
                },
                0x0e001c00 => {
                    if (bytes != 16) return error.UndefinedInstruction;
                    self.v[rd] = replaceLane(old, index, lane_bytes, self.reg(rn, 64, false));
                },
                0x0e003c00 => {
                    if ((bytes == 16) != (lane_bytes == 8)) return error.UndefinedInstruction;
                    self.setReg(rd, vectorLane(a, index, lane_bytes), if (bytes == 16) 64 else 32, false);
                },
                0x0e002c00 => {
                    if (lane_bytes >= (if (bytes == 16) @as(u8, 8) else 4)) return error.UndefinedInstruction;
                    self.setReg(rd, signExtend(vectorLane(a, index, lane_bytes), @intCast(lane_bytes * 8)), if (bytes == 16) 64 else 32, false);
                },
                else => unreachable,
            }
            return true;
        }
        if (ins & 0xffe08400 == 0x6e000400) {
            const imm5: u5 = @truncate(ins >> 16);
            if (imm5 == 0) return error.UndefinedInstruction;
            const scale: u3 = @intCast(@ctz(imm5));
            if (scale > 3) return error.UndefinedInstruction;
            const lane_bytes: u8 = @as(u8, 1) << scale;
            const source_index: u5 = @intCast(((ins >> 11) & 15) >> scale);
            const destination_index: u5 = @intCast(imm5 >> @intCast(scale + 1));
            if (((ins >> 11) & 15) & (lane_bytes - 1) != 0) return error.UndefinedInstruction;
            self.v[rd] = replaceLane(old, destination_index, lane_bytes, vectorLane(a, source_index, lane_bytes));
            return true;
        }
        if (ins & 0x9ff80c00 == 0x0f000400) {
            const cmode: u4 = @truncate(ins >> 12);
            const op = ins & 0x20000000 != 0;
            const immediate: u8 = @intCast(((ins >> 16) & 7) << 5 | ((ins >> 5) & 31));
            var expanded: u128 = undefined;
            if (cmode < 8) expanded = replicate(@as(u64, immediate) << (@as(u6, cmode >> 1) * 8), 4, bytes) else if (cmode < 12)
                expanded = replicate(@as(u64, immediate) << @as(u6, if (cmode & 2 != 0) 8 else 0), 2, bytes)
            else switch (cmode) {
                12 => expanded = replicate((@as(u64, immediate) << 8) | 255, 4, bytes),
                13 => expanded = replicate((@as(u64, immediate) << 16) | 65535, 4, bytes),
                14 => {
                    if (op) {
                        var element: u64 = 0;
                        for (0..8) |bit| if (immediate & (@as(u8, 1) << @intCast(bit)) != 0) {
                            element |= @as(u64, 255) << @intCast(bit * 8);
                        };
                        expanded = replicate(element, 8, bytes);
                    } else expanded = replicate(immediate, 1, bytes);
                },
                15 => {
                    if (op and bytes != 16) return error.UndefinedInstruction;
                    expanded = replicate(expandFloatImmediate(immediate, if (op) 64 else 32), if (op) 8 else 4, bytes);
                },
                else => unreachable,
            }
            if (cmode < 12 and cmode & 1 != 0) self.v[rd] = (if (op) old & ~expanded else old | expanded) & vector_mask else self.v[rd] = (if (op and cmode < 14) ~expanded else expanded) & vector_mask;
            return true;
        }
        if (ins & 0xbfe08400 == 0x2e000000) {
            const offset: u4 = @truncate(ins >> 11);
            if (offset >= bytes) return error.UndefinedInstruction;
            const shift: u7 = @as(u7, offset) * 8;
            self.v[rd] = if (offset == 0) a & vector_mask else ((a >> shift) | (b << @intCast(@as(u8, bytes) * 8 - shift))) & vector_mask;
            return true;
        }
        if (ins & 0xbf20fc00 == 0x0e208400 or ins & 0xbf20fc00 == 0x2e208400) {
            const lane_bytes: u8 = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
            if (lane_bytes == 8 and bytes != 16) return error.UndefinedInstruction;
            var value: u128 = 0;
            var lane: u5 = 0;
            while (lane < bytes / lane_bytes) : (lane += 1) {
                const first = vectorLane(a, lane, lane_bytes);
                const second = vectorLane(b, lane, lane_bytes);
                value = replaceLane(value, lane, lane_bytes, if (ins & 0x20000000 != 0) first -% second else first +% second);
            }
            self.v[rd] = value;
            return true;
        }
        const three_same = ins & 0xbf20fc00;
        if (three_same == 0x0e20bc00 or three_same == 0x0e203400 or three_same == 0x0e203c00 or
            three_same == 0x2e203400 or three_same == 0x2e203c00 or three_same == 0x0e208c00 or three_same == 0x2e208c00 or
            ins & 0xbf3ffc00 == 0x0e209800)
        {
            const lane_bytes: u8 = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
            if (lane_bytes == 8 and bytes != 16) return error.UndefinedInstruction;
            const count = bytes / lane_bytes;
            var value: u128 = 0;
            for (0..count) |lane| {
                var element: u64 = undefined;
                const first = vectorLane(a, @intCast(lane), lane_bytes);
                const second = vectorLane(b, @intCast(lane), lane_bytes);
                if (three_same == 0x0e20bc00) {
                    const source = if (lane < count / 2) a else b;
                    const pair: u5 = @intCast((lane % (count / 2)) * 2);
                    element = vectorLane(source, pair, lane_bytes) +% vectorLane(source, pair + 1, lane_bytes);
                } else {
                    const signed_first: i64 = @bitCast(signExtend(first, @intCast(lane_bytes * 8)));
                    const signed_second: i64 = @bitCast(signExtend(second, @intCast(lane_bytes * 8)));
                    const matches = switch (three_same) {
                        0x0e203400 => signed_first > signed_second,
                        0x0e203c00 => signed_first >= signed_second,
                        0x2e203400 => first > second,
                        0x2e203c00 => first >= second,
                        0x0e208c00 => first & second != 0,
                        0x2e208c00 => first == second,
                        else => first == 0,
                    };
                    element = if (matches) std.math.maxInt(u64) else 0;
                }
                value = replaceLane(value, @intCast(lane), lane_bytes, element);
            }
            self.v[rd] = value;
            return true;
        }
        if (ins & 0xbf000000 == 0x0c000000) {
            if (ins & 0x00200000 != 0) return error.UndefinedInstruction;
            const post = ins & 0x00800000 != 0;
            if (!post and rm != 0) return error.UndefinedInstruction;
            const load = ins & 0x00400000 != 0;
            const opcode: u4 = @truncate(ins >> 12);
            const repetitions: u8 = switch (opcode) {
                2 => 4,
                6 => 3,
                10 => 2,
                0, 4, 7, 8 => 1,
                else => return error.UndefinedInstruction,
            };
            const structures: u8 = switch (opcode) {
                0 => 4,
                4 => 3,
                8 => 2,
                else => 1,
            };
            const lane_bytes: u8 = @as(u8, 1) << @as(u2, @truncate(ins >> 10));
            if (lane_bytes == 8 and bytes == 8 and structures != 1) return error.UndefinedInstruction;
            const total: u8 = repetitions * structures * bytes;
            const address = self.reg(rn, 64, true);
            var buffer: [64]u8 = undefined;
            if (load) try memory.read(address, buffer[0..total]);
            var vectors: [4]u128 = @splat(0);
            var offset: u8 = 0;
            for (0..repetitions) |iteration| {
                for (0..bytes / lane_bytes) |lane| {
                    for (0..structures) |structure| {
                        const register: u5 = @truncate(@as(usize, rd) + iteration * structures + structure);
                        const slot = iteration * structures + structure;
                        if (load) vectors[slot] = replaceLane(vectors[slot], @intCast(lane), lane_bytes, readLaneBytes(buffer[offset..][0..lane_bytes])) else writeLaneBytes(buffer[offset..][0..lane_bytes], vectorLane(self.v[register], @intCast(lane), lane_bytes));
                        offset += lane_bytes;
                    }
                }
            }
            if (load) {
                for (vectors[0 .. repetitions * structures], 0..) |value, slot| self.v[@as(u5, @truncate(@as(usize, rd) + slot))] = value;
            } else {
                try memory.write(address, buffer[0..total]);
                self.clearExclusive();
            }
            if (post) self.setReg(rn, address +% (if (rm == 31) @as(u64, total) else self.reg(rm, 64, false)), 64, true);
            return true;
        }
        if (ins & 0xbf000000 == 0x0d000000) {
            const post = ins & 0x00800000 != 0;
            if (!post and rm != 0) return error.UndefinedInstruction;
            const load = ins & 0x00400000 != 0;
            const opcode: u3 = @truncate(ins >> 13);
            const structures: u8 = @as(u8, opcode & 1) * 2 + @as(u8, @intCast((ins >> 21) & 1)) + 1;
            const size: u2 = @truncate(ins >> 10);
            const s: u1 = @truncate(ins >> 12);
            const q: u1 = @truncate(ins >> 30);
            var scale: u2 = @intCast(opcode >> 1);
            var index: u5 = 0;
            const broadcast = scale == 3;
            switch (scale) {
                0 => index = @as(u5, q) * 8 + @as(u5, s) * 4 + size,
                1 => {
                    if (size & 1 != 0) return error.UndefinedInstruction;
                    index = @as(u5, q) * 4 + @as(u5, s) * 2 + (size >> 1);
                },
                2 => {
                    if (size & 2 != 0) return error.UndefinedInstruction;
                    if (size & 1 != 0) {
                        if (s != 0) return error.UndefinedInstruction;
                        scale = 3;
                        index = q;
                    } else index = @as(u5, q) * 2 + s;
                },
                3 => {
                    if (!load or s != 0) return error.UndefinedInstruction;
                    scale = size;
                },
            }
            const lane_bytes: u8 = @as(u8, 1) << scale;
            const total: u8 = structures * lane_bytes;
            const address = self.reg(rn, 64, true);
            var buffer: [32]u8 = undefined;
            if (load) try memory.read(address, buffer[0..total]);
            for (0..structures) |structure| {
                const register: u5 = @truncate(@as(usize, rd) + structure);
                const lane_buffer = buffer[structure * lane_bytes ..][0..lane_bytes];
                if (load) {
                    const element = readLaneBytes(lane_buffer);
                    self.v[register] = if (broadcast) replicate(element, lane_bytes, bytes) else replaceLane(self.v[register], index, lane_bytes, element);
                } else writeLaneBytes(lane_buffer, vectorLane(self.v[register], index, lane_bytes));
            }
            if (!load) {
                try memory.write(address, buffer[0..total]);
                self.clearExclusive();
            }
            if (post) self.setReg(rn, address +% (if (rm == 31) @as(u64, total) else self.reg(rm, 64, false)), 64, true);
            return true;
        }
        const fp_conversion = ins & 0x9fbffc00;
        if (fp_conversion == 0x0e21d800 or fp_conversion == 0x1e21d800 or fp_conversion == 0x0ea1b800 or fp_conversion == 0x1ea1b800) {
            try self.fpControl();
            const scalar = ins & 0x10000000 != 0;
            const double = ins & 0x00400000 != 0;
            const count: u8 = if (scalar) 1 else bytes / @as(u8, if (double) 8 else 4);
            if (!scalar and double and bytes == 8) return error.UndefinedInstruction;
            if (double) self.v[rd] = self.fpVectorConvert(f64, a, ins & 0x00800000 != 0, ins & 0x20000000 != 0, count) else self.v[rd] = self.fpVectorConvert(f32, a, ins & 0x00800000 != 0, ins & 0x20000000 != 0, count);
            return true;
        }
        return false;
    }

    fn fpVectorConvert(self: *Cpu, comptime T: type, source: u128, to_integer: bool, unsigned: bool, count: u8) u128 {
        const width: u7 = @bitSizeOf(T);
        const lane_bytes: u8 = @sizeOf(T);
        var result: u128 = 0;
        for (0..count) |lane| {
            const bits = vectorLane(source, @intCast(lane), lane_bytes);
            const value: u64 = if (to_integer) blk: {
                const input: T = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(bits)));
                break :blk self.fpInteger(self.fpInput(T, input), width, 3, unsigned);
            } else blk: {
                const number: f128 = if (unsigned) @floatFromInt(bits) else @floatFromInt(@as(i64, @bitCast(signExtend(bits, width))));
                break :blk floatBits(T, self.fpRound(T, number));
            };
            result = replaceLane(result, @intCast(lane), lane_bytes, value);
        }
        return result;
    }

    fn floatingPoint(self: *Cpu, ins: u32) !bool {
        if (ins & 0x5f20fc00 == 0x1e200000 or ins & 0x5f200000 == 0x1e000000) {
            const rd: u5 = @truncate(ins);
            const rn: u5 = @truncate(ins >> 5);
            const opcode: u5 = @truncate(ins >> 16);
            const float_type: u2 = @truncate(ins >> 22);
            const width: u7 = if (ins >> 31 != 0) 64 else 32;
            if (ins & 0x00200000 != 0 and (opcode == 6 or opcode == 7 or opcode == 14 or opcode == 15)) {
                if ((float_type == 0 and width != 32) or (float_type == 1 and width != 64) or float_type == 3 or
                    (float_type == 2 and (width != 64 or opcode < 14)) or (float_type != 2 and opcode >= 14)) return error.UndefinedInstruction;
                const upper = opcode >= 14;
                if (opcode & 1 == 0) self.setReg(rd, @truncate(self.v[rn] >> @as(u7, if (upper) 64 else 0)), width, false) else if (upper)
                    self.v[rd] = replaceLane(self.v[rd], 1, 8, self.reg(rn, 64, false))
                else
                    self.v[rd] = self.reg(rn, width, false);
                return true;
            }
            return switch (float_type) {
                0 => self.fpConvert(f32, ins, width),
                1 => self.fpConvert(f64, ins, width),
                else => error.UnsupportedInstruction,
            };
        }
        if (ins & 0xff000000 == 0x1e000000 or ins & 0xff000000 == 0x1f000000) {
            return switch (@as(u2, @truncate(ins >> 22))) {
                0 => self.fpScalar(f32, ins),
                1 => self.fpScalar(f64, ins),
                else => error.UnsupportedInstruction,
            };
        }
        return false;
    }

    fn getFloat(self: *const Cpu, comptime T: type, index: u5) T {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        return @bitCast(@as(Bits, @truncate(self.v[index])));
    }

    fn setFloat(self: *Cpu, comptime T: type, index: u5, value: T) void {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        self.v[index] = @as(Bits, @bitCast(value));
    }

    fn fpControl(self: *const Cpu) !void {
        if (self.fpcr & 0x00009f00 != 0) return error.UnsupportedFloatingPointTrap;
    }

    fn fpInput(self: *Cpu, comptime T: type, value: T) T {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        const bits: Bits = @bitCast(value);
        const exponent_mask = floatExponentMask(T);
        if (bits & exponent_mask == 0 and bits & ~floatSignMask(T) != 0 and self.fpcr & 0x01000000 != 0) {
            self.fpsr |= 128;
            return @bitCast(bits & floatSignMask(T));
        }
        return value;
    }

    fn fpNaN(self: *Cpu, comptime T: type, operands: []const T) ?T {
        var first: ?T = null;
        for (operands) |value| {
            if (isSignalingNaN(T, value)) {
                self.fpsr |= 1;
                return if (self.fpcr & 0x02000000 != 0) defaultNaN(T) else quietNaN(T, value);
            }
            if (std.math.isNan(value) and first == null) first = value;
        }
        if (first) |value| return if (self.fpcr & 0x02000000 != 0) defaultNaN(T) else quietNaN(T, value);
        return null;
    }

    fn fpRound(self: *Cpu, comptime T: type, exact: f128) T {
        var result: T = @floatCast(exact);
        const mode: u2 = @truncate(self.fpcr >> 22);
        if (std.math.isNan(exact)) {
            self.fpsr |= 1;
            return defaultNaN(T);
        }
        if (mode != 0) {
            const widened: f128 = result;
            if ((mode == 1 and widened < exact) or (mode == 3 and exact < 0 and widened < exact)) result = nextFloat(T, result, true);
            if ((mode == 2 and widened > exact) or (mode == 3 and exact > 0 and widened > exact)) result = nextFloat(T, result, false);
        }
        if (std.math.isFinite(exact) and @as(f128, result) != exact) {
            self.fpsr |= 16;
            if (std.math.isInf(@as(T, @floatCast(exact)))) self.fpsr |= 4;
            const bits = floatBits(T, result);
            if (bits & floatExponentMask(T) == 0) self.fpsr |= 8;
        }
        const bits = floatBits(T, result);
        if (self.fpcr & 0x01000000 != 0 and bits & floatExponentMask(T) == 0 and bits & ~floatSignMask(T) != 0) {
            self.fpsr |= 8;
            result = @bitCast(bits & floatSignMask(T));
        }
        return result;
    }

    fn fpCompare(self: *Cpu, comptime T: type, a_raw: T, b_raw: T, signal_quiet_nan: bool) void {
        const a = self.fpInput(T, a_raw);
        const b = self.fpInput(T, b_raw);
        if (std.math.isNan(a) or std.math.isNan(b)) {
            self.nzcv = 3;
            if (signal_quiet_nan or isSignalingNaN(T, a) or isSignalingNaN(T, b)) self.fpsr |= 1;
        } else self.nzcv = if (a == b) 6 else if (a < b) 8 else 2;
    }

    fn fpScalar(self: *Cpu, comptime T: type, ins: u32) !bool {
        const rd: u5 = @truncate(ins);
        const rn: u5 = @truncate(ins >> 5);
        const rm: u5 = @truncate(ins >> 16);
        const a_raw = self.getFloat(T, rn);
        const b_raw = self.getFloat(T, rm);
        if (ins & 0xff201fe0 == 0x1e201000) {
            self.v[rd] = expandFloatImmediate(@truncate(ins >> 13), @bitSizeOf(T));
            return true;
        }
        if (ins & 0xff200c00 == 0x1e200c00) {
            self.v[rd] = if (self.condition(@truncate(ins >> 12))) floatBits(T, a_raw) else floatBits(T, b_raw);
            return true;
        }
        if (ins & 0xff207c00 == 0x1e204000) {
            const opcode: u6 = @truncate(ins >> 15);
            switch (opcode) {
                0 => self.v[rd] = floatBits(T, a_raw),
                1 => self.v[rd] = floatBits(T, a_raw) & ~floatSignMask(T),
                2 => self.v[rd] = floatBits(T, a_raw) ^ floatSignMask(T),
                else => {
                    try self.fpControl();
                    if (opcode == 4 and T == f64) {
                        const input = self.fpInput(T, a_raw);
                        if (self.fpNaN(T, &.{input})) |nan| {
                            const sign: u32 = @truncate(floatBits(T, nan) >> 32 & 0x80000000);
                            const payload: u32 = @truncate(floatBits(T, nan) >> 29 & 0x003fffff);
                            self.v[rd] = sign | 0x7fc00000 | payload;
                        } else self.setFloat(f32, rd, self.fpRound(f32, input));
                    } else if (opcode == 5 and T == f32) {
                        const input = self.fpInput(T, a_raw);
                        if (self.fpNaN(T, &.{input})) |nan| {
                            const sign: u64 = @as(u64, floatBits(T, nan) & 0x80000000) << 32;
                            const payload: u64 = @as(u64, floatBits(T, nan) & 0x003fffff) << 29;
                            self.v[rd] = sign | 0x7ff8000000000000 | payload;
                        } else self.setFloat(f64, rd, input);
                    } else if (opcode == 3 or (opcode >= 8 and opcode <= 15 and opcode != 13)) {
                        const a = self.fpInput(T, a_raw);
                        if (self.fpNaN(T, &.{a})) |nan| self.setFloat(T, rd, nan) else if (opcode == 3) {
                            const exact = @sqrt(@as(f128, a));
                            self.setFloat(T, rd, self.fpRound(T, exact));
                        } else {
                            const mode: u3 = if (opcode >= 14) @as(u3, @truncate(self.fpcr >> 22)) else @intCast(opcode - 8);
                            const rounded = roundIntegral(a, mode);
                            if (opcode == 14 and rounded != a) self.fpsr |= 16;
                            self.setFloat(T, rd, @floatCast(rounded));
                        }
                    } else return error.UnsupportedInstruction;
                },
            }
            return true;
        }
        if (ins & 0xff20fc00 == 0x1e202000) {
            if (ins & 7 != 0 or (ins & 8 != 0 and rm != 0)) return error.UndefinedInstruction;
            try self.fpControl();
            self.fpCompare(T, a_raw, if (ins & 8 != 0) 0 else b_raw, ins & 16 != 0);
            return true;
        }
        if (ins & 0xff200c00 == 0x1e200400) {
            try self.fpControl();
            if (self.condition(@truncate(ins >> 12))) self.fpCompare(T, a_raw, b_raw, ins & 16 != 0) else self.nzcv = @truncate(ins);
            return true;
        }
        if (ins & 0xff200c00 == 0x1e200800) {
            const opcode: u4 = @truncate(ins >> 12);
            if (opcode > 8) return error.UnsupportedInstruction;
            try self.fpControl();
            const a = self.fpInput(T, a_raw);
            const b = self.fpInput(T, b_raw);
            var value: T = undefined;
            if ((opcode == 6 or opcode == 7) and !isSignalingNaN(T, a) and !isSignalingNaN(T, b) and (std.math.isNan(a) != std.math.isNan(b))) {
                value = if (std.math.isNan(a)) b else a;
            } else if (self.fpNaN(T, &.{ a, b })) |nan| value = nan else if (opcode >= 4 and opcode <= 7) {
                const minimum = opcode & 1 != 0;
                if (a == 0 and b == 0) {
                    const signs = if (minimum) floatBits(T, a) | floatBits(T, b) else floatBits(T, a) & floatBits(T, b);
                    value = @bitCast(signs & floatSignMask(T));
                } else value = if ((a < b) == minimum) a else b;
            } else {
                const exact: f128 = switch (opcode) {
                    0 => @as(f128, a) * @as(f128, b),
                    1 => @as(f128, a) / @as(f128, b),
                    2 => @as(f128, a) + @as(f128, b),
                    3 => @as(f128, a) - @as(f128, b),
                    8 => -(@as(f128, a) * @as(f128, b)),
                    else => unreachable,
                };
                if (opcode == 1 and b == 0 and a != 0 and std.math.isFinite(a)) self.fpsr |= 2;
                value = self.fpRound(T, exact);
                if (exact == 0 and (opcode == 2 or opcode == 3)) {
                    const b_sign = floatBits(T, b) ^ (if (opcode == 3) floatSignMask(T) else 0);
                    const a_sign = floatBits(T, a);
                    const negative = if ((a_sign ^ b_sign) & floatSignMask(T) == 0) a_sign & floatSignMask(T) != 0 else self.fpcr & 0x00c00000 == 0x00800000;
                    value = @bitCast(if (negative) floatSignMask(T) else @as(@Int(.unsigned, @bitSizeOf(T)), 0));
                }
            }
            self.setFloat(T, rd, value);
            return true;
        }
        if (ins & 0xff000000 == 0x1f000000) {
            try self.fpControl();
            const ra: u5 = @truncate(ins >> 10);
            var a = self.fpInput(T, a_raw);
            const b = self.fpInput(T, b_raw);
            var c = self.fpInput(T, self.getFloat(T, ra));
            if (ins & 0x00200000 != 0) c = -c;
            if ((ins & 0x00200000 != 0) != (ins & 0x00008000 != 0)) a = -a;
            if (self.fpNaN(T, &.{ c, a, b })) |nan| self.setFloat(T, rd, nan) else {
                const exact = @mulAdd(f128, a, b, c);
                var value = self.fpRound(T, exact);
                if (self.fpcr & 0x00c00000 == 0 and self.fpcr & 0x01000000 == 0 and !std.math.isNan(value)) value = @mulAdd(T, a, b, c);
                self.setFloat(T, rd, value);
            }
            return true;
        }
        return false;
    }

    fn fpConvert(self: *Cpu, comptime T: type, ins: u32, width: u7) !bool {
        const rd: u5 = @truncate(ins);
        const rn: u5 = @truncate(ins >> 5);
        const opcode: u5 = @truncate(ins >> 16);
        const fixed = ins & 0x00200000 == 0;
        const fractional_bits: u7 = if (fixed) 64 - @as(u7, @intCast((ins >> 10) & 63)) else 0;
        if (fixed and fractional_bits > width) return error.UndefinedInstruction;
        if (fixed and opcode != 2 and opcode != 3 and opcode != 24 and opcode != 25) return error.UndefinedInstruction;
        try self.fpControl();
        const scale: f128 = @floatFromInt(@as(u128, 1) << @intCast(fractional_bits));
        if (opcode == 2 or opcode == 3) {
            const bits = self.reg(rn, width, false);
            const number: f128 = if (opcode == 2) @floatFromInt(@as(i64, @bitCast(signExtend(bits, width)))) else @floatFromInt(bits);
            self.setFloat(T, rd, self.fpRound(T, number / scale));
        } else {
            const mode: u3 = switch (opcode & 30) {
                0 => 0,
                4 => 4,
                8 => 1,
                16 => 2,
                24 => 3,
                else => return error.UnsupportedInstruction,
            };
            const number = self.fpInput(T, self.getFloat(T, rn));
            const scaled: f128 = @as(f128, number) * scale;
            const unsigned = opcode & 1 != 0;
            self.setReg(rd, self.fpInteger(scaled, width, mode, unsigned), width, false);
        }
        return true;
    }

    fn fpInteger(self: *Cpu, input: f128, width: u7, mode: u3, unsigned: bool) u64 {
        const rounded = roundIntegral(input, mode);
        const bound: f128 = @floatFromInt(@as(u128, 1) << @intCast(if (unsigned) width else width - 1));
        if (std.math.isNan(input)) {
            self.fpsr |= 1;
            return 0;
        }
        if (rounded >= bound) {
            self.fpsr |= 1;
            return if (unsigned) mask(width) else mask(width - 1);
        }
        if (rounded < (if (unsigned) @as(f128, 0) else -bound)) {
            self.fpsr |= 1;
            return if (unsigned) 0 else @as(u64, 1) << @intCast(width - 1);
        }
        if (input != rounded) self.fpsr |= 16;
        return if (unsigned) @intFromFloat(rounded) else @bitCast(@as(i64, @intFromFloat(rounded)));
    }

    fn transfer(self: *Cpu, memory: *Memory, address: u64, rt: u5, size: u2, opc: u2, vector: bool) !void {
        if (vector) {
            if (opc >= 2 and size != 0) return error.UndefinedInstruction;
            const bytes: u8 = if (opc >= 2) 16 else @as(u8, 1) << size;
            if (opc & 1 != 0) self.v[rt] = try readSized(memory, address, bytes) else {
                try writeSized(memory, address, bytes, self.v[rt]);
                self.clearExclusive();
            }
            return;
        }
        if (size == 3 and opc == 2) return; // PRFM.
        if ((size >= 2 and opc == 3) or (size == 3 and opc >= 2)) return error.UndefinedInstruction;
        const bytes: u8 = @as(u8, 1) << size;
        if (opc == 0) {
            try writeSized(memory, address, bytes, self.reg(rt, 64, false));
            self.clearExclusive();
        } else {
            var value: u64 = @truncate(try readSized(memory, address, bytes));
            if (opc >= 2) value = signExtend(value, @intCast(bytes * 8));
            self.setReg(rt, value, if (size == 3 or opc == 2) 64 else 32, false);
        }
    }
};

fn mask(width: u7) u64 {
    return if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn vectorLane(value: u128, index: u5, bytes: u8) u64 {
    return @as(u64, @truncate(value >> @intCast(@as(u8, index) * bytes * 8))) & mask(@intCast(bytes * 8));
}

fn replaceLane(value: u128, index: u5, bytes: u8, element: u64) u128 {
    const shift: u7 = @intCast(@as(u8, index) * bytes * 8);
    const lane_mask: u128 = mask(@intCast(bytes * 8));
    return (value & ~(lane_mask << shift)) | ((@as(u128, element) & lane_mask) << shift);
}

fn replicate(element: u64, lane_bytes: u8, bytes: u8) u128 {
    var value: u128 = 0;
    var lane: u5 = 0;
    while (lane < bytes / lane_bytes) : (lane += 1) value = replaceLane(value, lane, lane_bytes, element);
    return value;
}

fn readLaneBytes(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (bytes, 0..) |byte, index| result |= @as(u64, byte) << @intCast(index * 8);
    return result;
}

fn writeLaneBytes(bytes: []u8, value: u64) void {
    for (bytes, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

fn expandFloatImmediate(immediate: u8, width: u7) u64 {
    const exponent_bits: u6 = if (width == 64) 11 else 8;
    const fraction_bits: u6 = if (width == 64) 52 else 23;
    const bit6 = (immediate >> 6) & 1;
    const exponent = (@as(u64, bit6 ^ 1) << (exponent_bits - 1)) |
        ((if (bit6 != 0) mask(exponent_bits - 3) else @as(u64, 0)) << 2) | ((immediate >> 4) & 3);
    return (@as(u64, immediate >> 7) << @intCast(width - 1)) | (exponent << fraction_bits) |
        (@as(u64, immediate & 15) << (fraction_bits - 4));
}

fn floatSignMask(comptime T: type) @Int(.unsigned, @bitSizeOf(T)) {
    return @as(@Int(.unsigned, @bitSizeOf(T)), 1) << (@bitSizeOf(T) - 1);
}

fn floatExponentMask(comptime T: type) @Int(.unsigned, @bitSizeOf(T)) {
    return if (T == f32) 0x7f800000 else 0x7ff0000000000000;
}

fn floatBits(comptime T: type, value: T) @Int(.unsigned, @bitSizeOf(T)) {
    return @bitCast(value);
}

fn defaultNaN(comptime T: type) T {
    return @bitCast(floatExponentMask(T) | (@as(@Int(.unsigned, @bitSizeOf(T)), 1) << @as(u6, if (T == f32) 22 else 51)));
}

fn quietNaN(comptime T: type, value: T) T {
    const quiet = @as(@Int(.unsigned, @bitSizeOf(T)), 1) << @as(u6, if (T == f32) 22 else 51);
    return @bitCast(floatBits(T, value) | quiet);
}

fn isSignalingNaN(comptime T: type, value: T) bool {
    const quiet = @as(@Int(.unsigned, @bitSizeOf(T)), 1) << @as(u6, if (T == f32) 22 else 51);
    return std.math.isNan(value) and floatBits(T, value) & quiet == 0;
}

fn nextFloat(comptime T: type, value: T, up: bool) T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    var bits: Bits = @bitCast(value);
    if (std.math.isNan(value) or (std.math.isInf(value) and (value > 0) == up)) return value;
    if (value == 0) return @bitCast(@as(Bits, 1) | (if (up) @as(Bits, 0) else floatSignMask(T)));
    if ((value > 0) == up) bits += 1 else bits -= 1;
    return @bitCast(bits);
}

fn roundIntegral(value: f128, mode: u3) f128 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const rounded = switch (mode) {
        0 => blk: {
            const lower = @floor(value);
            const fraction = value - lower;
            break :blk if (fraction > 0.5 or (fraction == 0.5 and @mod(lower, 2) != 0)) lower + 1 else lower;
        },
        1 => @ceil(value),
        2 => @floor(value),
        3 => @trunc(value),
        4 => @round(value),
        else => unreachable,
    };
    return if (rounded == 0 and value < 0) -@as(f128, 0) else rounded;
}

fn signedImmediate(value: u32, bits: u7) u64 {
    return signExtend(value, bits);
}

fn signExtend(value: u64, bits: u7) u64 {
    const sign = @as(u64, 1) << @intCast(bits - 1);
    return ((value & mask(bits)) ^ sign) -% sign;
}

fn rotateRight(value: u64, amount: u6, width: u7) u64 {
    const n: u6 = @intCast(@as(u7, amount) % width);
    const source = value & mask(width);
    return if (n == 0) source else ((source >> n) | (source << @intCast(width - n))) & mask(width);
}

fn shifted(value: u64, kind: u2, amount: u6, width: u7) u64 {
    const source = value & mask(width);
    return switch (kind) {
        0 => (source << amount) & mask(width),
        1 => source >> amount,
        2 => @bitCast(@as(i64, @bitCast(signExtend(source, width))) >> amount),
        3 => rotateRight(source, amount, width),
    };
}

fn extend(value: u64, option: u3) u64 {
    const bits: u7 = @as(u7, 8) << @as(u2, @truncate(option));
    return if (option & 4 != 0) signExtend(value, bits) else value & mask(bits);
}

fn signedDivide(a: u64, b: u64, width: u7) u64 {
    const lhs: i64 = @bitCast(signExtend(a, width));
    const rhs: i64 = @bitCast(signExtend(b, width));
    if (rhs == 0) return 0;
    // A64 wraps the one signed division whose mathematical result overflows.
    if (lhs == std.math.minInt(i64) and rhs == -1) return @bitCast(lhs);
    return @bitCast(@divTrunc(lhs, rhs));
}

fn reverseGroups(value: u64, width: u7, group: u7) u64 {
    var result: u64 = 0;
    var byte: u7 = 0;
    while (byte < width / 8) : (byte += 1) {
        const target = (byte / group) * group + group - 1 - byte % group;
        result |= ((value >> @intCast(byte * 8)) & 255) << @intCast(target * 8);
    }
    return result;
}

const BitMasks = struct { write: u64, top: u64 };

fn decodeBitMasks(n: u1, imms: u6, immr: u6, width: u7, immediate: bool) !BitMasks {
    const pattern: u7 = (@as(u7, n) << 6) | @as(u7, ~imms);
    if (pattern < 2) return error.UndefinedInstruction;
    const length: u3 = @intCast(6 - @clz(pattern));
    const element: u7 = @as(u7, 1) << length;
    if (element > width) return error.UndefinedInstruction;
    const levels: u6 = @intCast(element - 1);
    const s = imms & levels;
    const r = immr & levels;
    if (immediate and s == levels) return error.UndefinedInstruction;
    const difference = (s -% r) & levels;
    const write_element = rotateRight(mask(@as(u7, s) + 1), r, element);
    const top_element = mask(@as(u7, difference) + 1);
    var result: BitMasks = .{ .write = 0, .top = 0 };
    var offset: u7 = 0;
    while (offset < width) : (offset += element) {
        result.write |= write_element << @intCast(offset);
        result.top |= top_element << @intCast(offset);
    }
    return result;
}

fn readSized(memory: *Memory, address: u64, bytes: u8) !u128 {
    return switch (bytes) {
        1 => try memory.readInt(u8, address),
        2 => try memory.readInt(u16, address),
        4 => try memory.readInt(u32, address),
        8 => try memory.readInt(u64, address),
        16 => try memory.readInt(u128, address),
        else => unreachable,
    };
}

fn writeSized(memory: *Memory, address: u64, bytes: u8, value: u128) !void {
    switch (bytes) {
        1 => try memory.writeInt(u8, address, @truncate(value)),
        2 => try memory.writeInt(u16, address, @truncate(value)),
        4 => try memory.writeInt(u32, address, @truncate(value)),
        8 => try memory.writeInt(u64, address, @truncate(value)),
        16 => try memory.writeInt(u128, address, value),
        else => unreachable,
    }
}

fn executeTest(cpu: *Cpu, memory: *Memory, instruction: u32) !Event {
    try memory.writeInt(u32, cpu.pc, instruction);
    return cpu.step(memory);
}

fn testMemory() !Memory {
    var memory = Memory.init(std.testing.allocator);
    errdefer memory.deinit();
    try memory.map(0x1000, 0x3000, .{ .read = true, .write = true, .execute = true });
    return memory;
}

test "W writes zero extend; SP and zero register have encoding-specific roles" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0x3000);
    cpu.x[0] = std.math.maxInt(u64);
    _ = try executeTest(&cpu, &memory, 0x52800020); // MOVZ W0, #1
    try std.testing.expectEqual(@as(u64, 1), cpu.x[0]);
    _ = try executeTest(&cpu, &memory, 0xd10043ff); // SUB SP, SP, #16
    try std.testing.expectEqual(@as(u64, 0x2ff0), cpu.sp);
    _ = try executeTest(&cpu, &memory, 0xaa1f03e1); // ORR X1, XZR, XZR
    try std.testing.expectEqual(@as(u64, 0), cpu.x[1]);
    _ = try executeTest(&cpu, &memory, 0xf10003ff); // CMP SP, #0
    try std.testing.expectEqual(@as(u64, 0x2ff0), cpu.sp);
    try std.testing.expectEqual(@as(u4, 2), cpu.nzcv);
}

test "arithmetic flags cover carry borrow signed overflow and W width" {
    var cpu: Cpu = .{};
    try std.testing.expectEqual(@as(u64, 0), cpu.add(0xffffffff, 1, false, 32, true));
    try std.testing.expectEqual(@as(u4, 6), cpu.nzcv);
    try std.testing.expectEqual(@as(u64, 0x80000000), cpu.add(0x7fffffff, 1, false, 32, true));
    try std.testing.expectEqual(@as(u4, 9), cpu.nzcv);
    try std.testing.expectEqual(@as(u64, 0xffffffff), cpu.add(0, ~@as(u64, 1), true, 32, true));
    try std.testing.expectEqual(@as(u4, 8), cpu.nzcv);
    try std.testing.expectEqual(@as(u64, 0), cpu.add(0, ~@as(u64, 0), true, 64, true));
    try std.testing.expectEqual(@as(u4, 6), cpu.nzcv);
}

test "AddWithCarry flags exhaustively match mathematical sums at reduced width" {
    var cpu: Cpu = .{};
    for (0..256) |a| {
        for (0..256) |b| {
            for (0..2) |carry| {
                const unsigned_sum = a + b + carry;
                const signed_a: i16 = if (a < 128) @intCast(a) else @as(i16, @intCast(a)) - 256;
                const signed_b: i16 = if (b < 128) @intCast(b) else @as(i16, @intCast(b)) - 256;
                const signed_sum = signed_a + signed_b + @as(i16, @intCast(carry));
                const expected = unsigned_sum & 255;
                const flags: u4 = (@as(u4, @intFromBool(expected >= 128)) << 3) |
                    (@as(u4, @intFromBool(expected == 0)) << 2) |
                    (@as(u4, @intFromBool(unsigned_sum >= 256)) << 1) |
                    @as(u4, @intFromBool(signed_sum < -128 or signed_sum > 127));
                try std.testing.expectEqual(@as(u64, expected), cpu.add(a, b, carry != 0, 8, true));
                try std.testing.expectEqual(flags, cpu.nzcv);
            }
        }
    }
}

test "all condition codes match all sixteen NZCV states" {
    var cpu: Cpu = .{};
    for (0..16) |flags| {
        cpu.nzcv = @intCast(flags);
        const n = flags & 8 != 0;
        const z = flags & 4 != 0;
        const c = flags & 2 != 0;
        const v = flags & 1 != 0;
        const expected = [_]bool{ z, !z, c, !c, n, !n, v, !v, c and !z, !c or z, n == v, n != v, !z and n == v, z or n != v, true, true };
        for (expected, 0..) |result, condition| try std.testing.expectEqual(result, cpu.condition(@intCast(condition)));
    }
}

test "branch linking condition evaluation and instruction-relative offsets" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    _ = try executeTest(&cpu, &memory, 0x94000004); // BL PC+16
    try std.testing.expectEqual(@as(u64, 0x1010), cpu.pc);
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.x[30]);
    _ = try executeTest(&cpu, &memory, 0xd65f03c0); // RET
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.pc);
    cpu.nzcv = 4;
    _ = try executeTest(&cpu, &memory, 0x54000040); // B.EQ PC+8
    try std.testing.expectEqual(@as(u64, 0x100c), cpu.pc);
    _ = try executeTest(&cpu, &memory, 0x35ffffe0); // CBNZ W0, PC-4; zero => untaken
    try std.testing.expectEqual(@as(u64, 0x1010), cpu.pc);
    for (0..16) |cond| {
        cpu.nzcv = 0;
        const condition: u4 = @intCast(cond);
        if (condition == 14 or condition == 15) try std.testing.expect(cpu.condition(condition));
    }
}

test "bit masks repeat and rotate; bitfields sign extend and merge" {
    const repeated = try decodeBitMasks(0, 39, 0, 64, true);
    try std.testing.expectEqual(@as(u64, 0x00ff00ff00ff00ff), repeated.write);
    try std.testing.expectError(error.UndefinedInstruction, decodeBitMasks(1, 63, 0, 64, true));
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0x80;
    _ = try executeTest(&cpu, &memory, 0x93401c20); // SXTB X0, W1
    try std.testing.expectEqual(@as(u64, 0xffffffffffffff80), cpu.x[0]);
    cpu.x[1] = 0x123456789abcdef0;
    _ = try executeTest(&cpu, &memory, 0xd3483c20); // UBFX X0, X1, #8, #8
    try std.testing.expectEqual(@as(u64, 0xde), cpu.x[0]);
    cpu.x[0] = 0xffff;
    cpu.x[1] = 0;
    _ = try executeTest(&cpu, &memory, 0xb3781c20); // BFI X0, X1, #8, #8
    try std.testing.expectEqual(@as(u64, 0xff), cpu.x[0]);
}

test "loads stores signed bytes and pair stack writeback" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0x3000);
    cpu.x[0] = 0x1122334455667788;
    cpu.x[1] = 0x8877665544332211;
    _ = try executeTest(&cpu, &memory, 0xa9bf07e0); // STP X0, X1, [SP, #-16]!
    try std.testing.expectEqual(@as(u64, 0x2ff0), cpu.sp);
    try std.testing.expectEqual(cpu.x[0], try memory.readInt(u64, 0x2ff0));
    cpu.x[0] = 0;
    cpu.x[1] = 0;
    _ = try executeTest(&cpu, &memory, 0xa8c107e0); // LDP X0, X1, [SP], #16
    try std.testing.expectEqual(@as(u64, 0x3000), cpu.sp);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), cpu.x[1]);
    cpu.x[2] = 0x2000;
    try memory.writeInt(u8, 0x2000, 0x80);
    _ = try executeTest(&cpu, &memory, 0x39800040); // LDRSB X0, [X2]
    try std.testing.expectEqual(@as(u64, 0xffffffffffffff80), cpu.x[0]);
    _ = try executeTest(&cpu, &memory, 0x39c00041); // LDRSB W1, [X2]
    try std.testing.expectEqual(@as(u64, 0xffffff80), cpu.x[1]);
}

test "integer division zero overflow and signed high multiply" {
    try std.testing.expectEqual(@as(u64, 0), signedDivide(10, 0, 64));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), signedDivide(0x8000000000000000, 0xffffffffffffffff, 64));
    try std.testing.expectEqual(@as(u64, 0xfffffffffffffffe), signedDivide(0xfffffff9, 3, 32));
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0xffffffffffffffff;
    cpu.x[2] = 2;
    _ = try executeTest(&cpu, &memory, 0x9b427c20); // SMULH X0, X1, X2
    try std.testing.expectEqual(std.math.maxInt(u64), cpu.x[0]);
}

test "SVC advances PC and unsupported instructions preserve PC" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    const event = try executeTest(&cpu, &memory, 0xd40004e1); // SVC #0x27
    try std.testing.expectEqual(@as(u16, 0x27), event.svc);
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.pc);
    try std.testing.expectError(error.UndefinedInstruction, executeTest(&cpu, &memory, 0));
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.pc);
    try std.testing.expectEqual(@as(u64, 1), cpu.counter);
}

test "TLS registers round trip and NZCV is packed at architectural bit positions" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[0] = 0x123456;
    _ = try executeTest(&cpu, &memory, 0xd51bd040); // MSR TPIDR_EL0, X0
    _ = try executeTest(&cpu, &memory, 0xd53bd041); // MRS X1, TPIDR_EL0
    try std.testing.expectEqual(cpu.x[0], cpu.x[1]);
    cpu.nzcv = 11;
    _ = try executeTest(&cpu, &memory, 0xd53b4202); // MRS X2, NZCV
    try std.testing.expectEqual(@as(u64, 0xb0000000), cpu.x[2]);
}

test "Cortex A57 cache geometry and coherent guest cache maintenance" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    _ = try executeTest(&cpu, &memory, 0xd53b0028); // MRS X8, CTR_EL0
    try std.testing.expectEqual(@as(u64, 0x8444c004), cpu.x[8]);
    try std.testing.expectEqual(@as(u64, 64), @as(u64, 4) << @as(u6, @intCast(cpu.x[8] & 15)));
    try std.testing.expectEqual(@as(u64, 64), @as(u64, 4) << @as(u6, @intCast((cpu.x[8] >> 16) & 15)));
    cpu.x[9] = 0x2000;
    try memory.writeInt(u64, 0x2000, 0x1122334455667788);
    _ = try executeTest(&cpu, &memory, 0xd50b7e29); // DC CIVAC, X9
    _ = try executeTest(&cpu, &memory, 0xd50b7a29); // DC CVAC, X9
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), try memory.readInt(u64, 0x2000));
    _ = try executeTest(&cpu, &memory, 0xd53b00ea); // MRS X10, DCZID_EL0
    try std.testing.expectEqual(@as(u64, 4), cpu.x[10]);
    try memory.writeInt(u8, 0x203f, 0xab);
    try memory.writeInt(u8, 0x2080, 0xcd);
    const nonzero: [64]u8 = @splat(0x55);
    try memory.write(0x2040, &nonzero);
    cpu.x[9] = 0x2043;
    _ = try executeTest(&cpu, &memory, 0xd50b7429); // DC ZVA, X9
    var cleared: [64]u8 = undefined;
    try memory.read(0x2040, &cleared);
    const zeros: [64]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zeros, &cleared);
    try std.testing.expectEqual(@as(u8, 0xab), try memory.readInt(u8, 0x203f));
    try std.testing.expectEqual(@as(u8, 0xcd), try memory.readInt(u8, 0x2080));
}

test "exclusive store success and monitor clearing" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0x2000;
    try memory.writeInt(u64, 0x2000, 7);
    _ = try executeTest(&cpu, &memory, 0xc85f7c20); // LDXR X0, [X1]
    try std.testing.expectEqual(@as(u64, 7), cpu.x[0]);
    cpu.x[0] = 9;
    _ = try executeTest(&cpu, &memory, 0xc8027c20); // STXR W2, X0, [X1]
    try std.testing.expectEqual(@as(u64, 0), cpu.x[2]);
    try std.testing.expectEqual(@as(u64, 9), try memory.readInt(u64, 0x2000));
    _ = try executeTest(&cpu, &memory, 0xc8027c20);
    try std.testing.expectEqual(@as(u64, 1), cpu.x[2]);
}

test "conditional arithmetic selects shifts and carry instructions" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0xffffffff;
    cpu.x[2] = 0;
    cpu.nzcv = 2;
    _ = try executeTest(&cpu, &memory, 0x3a020020); // ADCS W0, W1, W2
    try std.testing.expectEqual(@as(u64, 0), cpu.x[0]);
    try std.testing.expectEqual(@as(u4, 6), cpu.nzcv);
    _ = try executeTest(&cpu, &memory, 0xda820420); // CSNEG X0, X1, X2, EQ
    try std.testing.expectEqual(@as(u64, 0xffffffff), cpu.x[0]);
    cpu.nzcv = 0;
    cpu.x[2] = 3;
    _ = try executeTest(&cpu, &memory, 0xda820420);
    try std.testing.expectEqual(@as(u64, 0xfffffffffffffffd), cpu.x[0]);
    _ = try executeTest(&cpu, &memory, 0xfa420023); // CCMP X1, X2, #3, EQ
    try std.testing.expectEqual(@as(u4, 3), cpu.nzcv);
    cpu.x[1] = 0x80000000;
    _ = try executeTest(&cpu, &memory, 0x13017c20); // ASR W0, W1, #1
    try std.testing.expectEqual(@as(u64, 0xc0000000), cpu.x[0]);
    _ = try executeTest(&cpu, &memory, 0x5ac00820); // REV W0, W1
    try std.testing.expectEqual(@as(u64, 0x80), cpu.x[0]);
}

test "literal register-offset and unscaled memory modes; SIMD memory preserves raw bits" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    try memory.writeInt(u64, 0x1100, 0x123456789abcdef0);
    _ = try executeTest(&cpu, &memory, 0x58000800); // LDR X0, PC+256
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), cpu.x[0]);
    cpu.x[1] = 0x2000;
    cpu.x[2] = 2;
    _ = try executeTest(&cpu, &memory, 0xf8227820); // STR X0, [X1, X2, LSL #3]
    try std.testing.expectEqual(cpu.x[0], try memory.readInt(u64, 0x2010));
    cpu.x[1] = 0x2018;
    _ = try executeTest(&cpu, &memory, 0xf85f8023); // LDUR X3, [X1, #-8]
    try std.testing.expectEqual(cpu.x[0], cpu.x[3]);
    cpu.v[0] = 0xffeeddccbbaa99887766554433221100;
    cpu.x[1] = 0x2100;
    _ = try executeTest(&cpu, &memory, 0x3d800020); // STR Q0, [X1]
    _ = try executeTest(&cpu, &memory, 0x3dc00021); // LDR Q1, [X1]
    try std.testing.expectEqual(cpu.v[0], cpu.v[1]);
    _ = try executeTest(&cpu, &memory, 0xbd400021); // LDR S1, [X1]
    try std.testing.expectEqual(@as(u128, 0x33221100), cpu.v[1]);
}

test "load faults and illegal encodings do not advance execution" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[0] = 123;
    cpu.x[1] = 0xdead0000;
    try std.testing.expectError(error.MemoryFault, executeTest(&cpu, &memory, 0xf9400020)); // LDR X0, [X1]
    try std.testing.expectEqual(@as(u64, 123), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, 0x1000), cpu.pc);
    try std.testing.expectEqual(@as(u64, 0), cpu.counter);
    try std.testing.expectError(error.UndefinedInstruction, executeTest(&cpu, &memory, 0x52c00000)); // MOVZ W0, #0, LSL #32
    try std.testing.expectError(error.UndefinedInstruction, executeTest(&cpu, &memory, 0x0bc10000)); // ADD W0, W0, W1, ROR #0
    cpu.pc = 0x1001;
    try std.testing.expectError(error.UnalignedInstruction, cpu.step(&memory));
}

test "SIMD immediate copies insertions logical operations and lane arithmetic" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    _ = try executeTest(&cpu, &memory, 0x4f0747e0); // MOVI V0.4S, #255, LSL #16
    try std.testing.expectEqual(@as(u128, 0x00ff000000ff000000ff000000ff0000), cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x6f05e540); // MOVI V0.2D, #0xff00ff00ff00ff00
    try std.testing.expectEqual(@as(u128, 0xff00ff00ff00ff00ff00ff00ff00ff00), cpu.v[0]);
    cpu.x[1] = 0x12;
    _ = try executeTest(&cpu, &memory, 0x4e010c20); // DUP V0.16B, W1
    try std.testing.expectEqual(@as(u128, 0x12121212121212121212121212121212), cpu.v[0]);
    cpu.v[1] = 0x1234567890abcdef1122334455667788;
    _ = try executeTest(&cpu, &memory, 0x4e140420); // DUP V0.4S, V1.S[2]
    try std.testing.expectEqual(@as(u128, 0x90abcdef90abcdef90abcdef90abcdef), cpu.v[0]);
    cpu.x[1] = 0xffffffffffffffff;
    _ = try executeTest(&cpu, &memory, 0x4e181c20); // INS V0.D[1], X1
    try std.testing.expectEqual(@as(u128, 0xffffffffffffffff90abcdef90abcdef), cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x6e146420); // INS V0.S[2], V1.S[3]
    try std.testing.expectEqual(@as(u128, 0xffffffff1234567890abcdef90abcdef), cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x0e073c20); // UMOV W0, V1.B[3]
    try std.testing.expectEqual(@as(u64, 0x55), cpu.x[0]);
    cpu.v[1] = 0xffffffff00000000ffffffff00000000;
    cpu.v[2] = 0x00000001000000010000000100000001;
    _ = try executeTest(&cpu, &memory, 0x4ea28420); // ADD V0.4S, V1.4S, V2.4S
    try std.testing.expectEqual(@as(u128, 0x00000000000000010000000000000001), cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x6e221c20); // EOR V0.16B, V1.16B, V2.16B
    try std.testing.expectEqual(cpu.v[1] ^ cpu.v[2], cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x2e221c20); // EOR V0.8B, V1.8B, V2.8B
    try std.testing.expectEqual(@as(u128, 0xfffffffe00000001), cpu.v[0]);
}

test "SIMD structure loads deinterleave and post-index stores serialize lanes" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0x2000;
    for (0..8) |index| try memory.writeInt(u32, 0x2000 + index * 4, @intCast(index + 1));
    _ = try executeTest(&cpu, &memory, 0x4c408820); // LD2 {V0.4S, V1.4S}, [X1]
    try std.testing.expectEqual(@as(u128, 0x00000007000000050000000300000001), cpu.v[0]);
    try std.testing.expectEqual(@as(u128, 0x00000008000000060000000400000002), cpu.v[1]);
    cpu.x[1] = 0x2100;
    cpu.x[2] = 32;
    _ = try executeTest(&cpu, &memory, 0x4c827820); // ST1 {V0.4S}, [X1], X2
    try std.testing.expectEqual(@as(u64, 0x2120), cpu.x[1]);
    try std.testing.expectEqual(cpu.v[0], try memory.readInt(u128, 0x2100));
    cpu.x[1] = 0x2000;
    _ = try executeTest(&cpu, &memory, 0x4cdfa020); // LD1 {V0.16B, V1.16B}, [X1], #32
    try std.testing.expectEqual(@as(u64, 0x2020), cpu.x[1]);
    try std.testing.expectEqual(try memory.readInt(u128, 0x2000), cpu.v[0]);
    try std.testing.expectEqual(try memory.readInt(u128, 0x2010), cpu.v[1]);
}

test "scalar floating point raw moves arithmetic conversion and fused operations" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0x7fc12345;
    _ = try executeTest(&cpu, &memory, 0x1e270020); // FMOV S0, W1
    try std.testing.expectEqual(@as(u128, 0x7fc12345), cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x1e260002); // FMOV W2, S0
    try std.testing.expectEqual(@as(u64, 0x7fc12345), cpu.x[2]);
    _ = try executeTest(&cpu, &memory, 0x1e2e1000); // FMOV S0, #1
    try std.testing.expectEqual(@as(f32, 1), cpu.getFloat(f32, 0));
    cpu.setFloat(f32, 1, 1.5);
    cpu.setFloat(f32, 2, 2.25);
    _ = try executeTest(&cpu, &memory, 0x1e222820); // FADD S0, S1, S2
    try std.testing.expectEqual(@as(f32, 3.75), cpu.getFloat(f32, 0));
    cpu.setFloat(f64, 1, 7);
    cpu.setFloat(f64, 2, 2);
    _ = try executeTest(&cpu, &memory, 0x1e623820); // FSUB D0, D1, D2
    try std.testing.expectEqual(@as(f64, 5), cpu.getFloat(f64, 0));
    _ = try executeTest(&cpu, &memory, 0x1e621820); // FDIV D0, D1, D2
    try std.testing.expectEqual(@as(f64, 3.5), cpu.getFloat(f64, 0));
    cpu.setFloat(f32, 1, 1.5);
    _ = try executeTest(&cpu, &memory, 0x1e22c020); // FCVT D0, S1
    try std.testing.expectEqual(@as(f64, 1.5), cpu.getFloat(f64, 0));
    cpu.setFloat(f64, 1, -3.5);
    _ = try executeTest(&cpu, &memory, 0x1e624020); // FCVT S0, D1
    try std.testing.expectEqual(@as(f32, -3.5), cpu.getFloat(f32, 0));
    cpu.x[1] = 0xfffffff9;
    _ = try executeTest(&cpu, &memory, 0x1e220020); // SCVTF S0, W1
    try std.testing.expectEqual(@as(f32, -7), cpu.getFloat(f32, 0));
    cpu.setFloat(f32, 1, -2.75);
    _ = try executeTest(&cpu, &memory, 0x1e380020); // FCVTZS W0, S1
    try std.testing.expectEqual(@as(u64, 0xfffffffe), cpu.x[0]);
    cpu.setFloat(f32, 1, 3);
    cpu.setFloat(f32, 2, 4);
    cpu.setFloat(f32, 3, 5);
    _ = try executeTest(&cpu, &memory, 0x1f020c20); // FMADD S0, S1, S2, S3
    try std.testing.expectEqual(@as(f32, 17), cpu.getFloat(f32, 0));
    _ = try executeTest(&cpu, &memory, 0x1f028c20); // FMSUB S0, S1, S2, S3
    try std.testing.expectEqual(@as(f32, -7), cpu.getFloat(f32, 0));
    _ = try executeTest(&cpu, &memory, 0x1f220c20); // FNMADD S0, S1, S2, S3
    try std.testing.expectEqual(@as(f32, -17), cpu.getFloat(f32, 0));
    _ = try executeTest(&cpu, &memory, 0x1f228c20); // FNMSUB S0, S1, S2, S3
    try std.testing.expectEqual(@as(f32, 7), cpu.getFloat(f32, 0));
}

test "floating point NaN payloads signed zeros exceptions saturation and directed rounding" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.v[1] = 0x7f812345;
    cpu.setFloat(f32, 2, 1);
    _ = try executeTest(&cpu, &memory, 0x1e222820);
    try std.testing.expectEqual(@as(u128, 0x7fc12345), cpu.v[0]);
    try std.testing.expectEqual(@as(u32, 1), cpu.fpsr);
    cpu.fpcr = 0x02000000;
    _ = try executeTest(&cpu, &memory, 0x1e222820);
    try std.testing.expectEqual(@as(u128, 0x7fc00000), cpu.v[0]);
    cpu.fpcr = 0;
    cpu.fpsr = 0;
    cpu.setFloat(f32, 1, -@as(f32, 0));
    cpu.setFloat(f32, 2, 0);
    _ = try executeTest(&cpu, &memory, 0x1e224820); // FMAX S0, S1, S2
    try std.testing.expectEqual(@as(u128, 0), cpu.v[0]);
    _ = try executeTest(&cpu, &memory, 0x1e225820); // FMIN S0, S1, S2
    try std.testing.expectEqual(@as(u128, 0x80000000), cpu.v[0]);
    cpu.setFloat(f32, 1, 1);
    _ = try executeTest(&cpu, &memory, 0x1e221820); // FDIV S0, S1, S2
    try std.testing.expectEqual(@as(u128, 0x7f800000), cpu.v[0]);
    try std.testing.expectEqual(@as(u32, 2), cpu.fpsr);
    cpu.setFloat(f32, 1, std.math.inf(f32));
    _ = try executeTest(&cpu, &memory, 0x1e380020);
    try std.testing.expectEqual(@as(u64, 0x7fffffff), cpu.x[0]);
    try std.testing.expect(cpu.fpsr & 1 != 0);
    cpu.fpcr = 0x00400000;
    cpu.setFloat(f32, 1, 1);
    cpu.setFloat(f32, 2, 0x1p-25);
    _ = try executeTest(&cpu, &memory, 0x1e222820);
    try std.testing.expectEqual(@as(u128, 0x3f800001), cpu.v[0]);
    cpu.fpcr = 0x00800000;
    cpu.setFloat(f32, 2, -1);
    _ = try executeTest(&cpu, &memory, 0x1e222820);
    try std.testing.expectEqual(@as(u128, 0x80000000), cpu.v[0]);
    cpu.fpcr = 0;
    cpu.v[1] = 0x7fc01234;
    _ = try executeTest(&cpu, &memory, 0x1e222020); // FCMP S1, S2
    try std.testing.expectEqual(@as(u4, 3), cpu.nzcv);
}

test "SIMD single-lane loads preserve neighbors and broadcasts replace the vector" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.x[1] = 0x2000;
    cpu.v[0] = std.math.maxInt(u128);
    try memory.writeInt(u8, 0x2000, 0x12);
    _ = try executeTest(&cpu, &memory, 0x0d400c20); // LD1 {V0.B}[3], [X1]
    try std.testing.expectEqual(@as(u128, 0xffffffffffffffffffffffff12ffffff), cpu.v[0]);
    try memory.writeInt(u32, 0x2000, 0x12345678);
    _ = try executeTest(&cpu, &memory, 0x4ddfc820); // LD1R {V0.4S}, [X1], #4
    try std.testing.expectEqual(@as(u128, 0x12345678123456781234567812345678), cpu.v[0]);
    try std.testing.expectEqual(@as(u64, 0x2004), cpu.x[1]);
}

test "SIMD scalar and vector integer floating point conversions use lane widths" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.v[1] = 0xfffffff9;
    _ = try executeTest(&cpu, &memory, 0x5e21d820); // SCVTF S0, S1
    try std.testing.expectEqual(@as(f32, -7), cpu.getFloat(f32, 0));
    cpu.setFloat(f64, 1, -2.75);
    _ = try executeTest(&cpu, &memory, 0x5ee1b820); // FCVTZS D0, D1
    try std.testing.expectEqual(@as(u128, 0xfffffffffffffffe), cpu.v[0]);
    cpu.v[1] = 0x0000000400000003fffffffeffffffff;
    _ = try executeTest(&cpu, &memory, 0x4e21d820); // SCVTF V0.4S, V1.4S
    try std.testing.expectEqual(@as(u128, 0x4080000040400000c0000000bf800000), cpu.v[0]);
    cpu.v[1] = cpu.v[0];
    _ = try executeTest(&cpu, &memory, 0x4ea1b820); // FCVTZS V0.4S, V1.4S
    try std.testing.expectEqual(@as(u128, 0x0000000400000003fffffffeffffffff), cpu.v[0]);
}

test "SIMD byte comparisons and pairwise reductions retain pair layout" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.v[1] = 0x00010203000004050006070008000900;
    cpu.v[0] = 0;
    _ = try executeTest(&cpu, &memory, 0x6e208c23); // CMEQ V3.16B, V1.16B, V0.16B
    try std.testing.expectEqual(@as(u128, 0xff000000ffff0000ff0000ff00ff00ff), cpu.v[3]);
    _ = try executeTest(&cpu, &memory, 0x4e209824); // CMEQ V4.16B, V1.16B, #0
    try std.testing.expectEqual(cpu.v[3], cpu.v[4]);
    cpu.v[3] = 0x100f0e0d0c0b0a090807060504030201;
    cpu.v[4] = 0x201f1e1d1c1b1a191817161514131211;
    _ = try executeTest(&cpu, &memory, 0x4e24bc66); // ADDP V6.16B, V3.16B, V4.16B
    try std.testing.expectEqual(@as(u128, 0x3f3b37332f2b27231f1b17130f0b0703), cpu.v[6]);
}

test "scalar SIMD SHL clears high bits and wraps at the D-register width" {
    var memory = try testMemory();
    defer memory.deinit();
    var cpu = Cpu.init(0x1000, 0);
    cpu.v[3] = 0xffffffffffffffff123456789abcdef0;
    _ = try executeTest(&cpu, &memory, 0x5f605463); // SHL D3, D3, #32
    try std.testing.expectEqual(@as(u128, 0x9abcdef000000000), cpu.v[3]);
    cpu.v[3] = 0xffffffffffffffff123456789abcdef1;
    _ = try executeTest(&cpu, &memory, 0x5f405463); // SHL D3, D3, #0
    try std.testing.expectEqual(@as(u128, 0x123456789abcdef1), cpu.v[3]);
    _ = try executeTest(&cpu, &memory, 0x5f7f5463); // SHL D3, D3, #63
    try std.testing.expectEqual(@as(u128, 0x8000000000000000), cpu.v[3]);
    try std.testing.expectError(error.UndefinedInstruction, executeTest(&cpu, &memory, 0x5f205463));
}
