//! Original AArch64 integer interpreter. Register 31 is resolved per encoding,
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
        if (ins & 0xffffffe0 == 0xd50b7b20 or ins & 0xffffffe0 == 0xd50b7520) return .next;
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
                0x0e000400 => self.v[rd] = replicate(vectorLane(a, index, lane_bytes), lane_bytes, bytes),
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
            if (cmode < 8) expanded = replicate(@as(u64, immediate) << @intCast((cmode >> 1) * 8), 4, bytes) else if (cmode < 12)
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
            if (cmode < 12 and cmode & 1 != 0) self.v[rd] = (if (op) old & ~expanded else old | expanded) & vector_mask else
                self.v[rd] = (if (op and cmode < 14) ~expanded else expanded) & vector_mask;
            return true;
        }
        if (ins & 0xbfe08400 == 0x2e000000) {
            const offset: u4 = @truncate(ins >> 11);
            if (offset >= bytes) return error.UndefinedInstruction;
            const shift: u7 = @as(u7, offset) * 8;
            self.v[rd] = if (offset == 0) a & vector_mask else
                ((a >> shift) | (b << @intCast(@as(u8, bytes) * 8 - shift))) & vector_mask;
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
        if (ins & 0xbf000000 == 0x0c000000) {
            if (ins & 0x00200000 != 0) return error.UndefinedInstruction;
            const post = ins & 0x00800000 != 0;
            if (!post and rm != 0) return error.UndefinedInstruction;
            const load = ins & 0x00400000 != 0;
            const opcode: u4 = @truncate(ins >> 12);
            const repetitions: u8 = switch (opcode) { 2 => 4, 6 => 3, 10 => 2, 0, 4, 7, 8 => 1, else => return error.UndefinedInstruction };
            const structures: u8 = switch (opcode) { 0 => 4, 4 => 3, 8 => 2, else => 1 };
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
                        if (load) vectors[slot] = replaceLane(vectors[slot], @intCast(lane), lane_bytes, readLaneBytes(buffer[offset..][0..lane_bytes])) else
                            writeLaneBytes(buffer[offset..][0..lane_bytes], vectorLane(self.v[register], @intCast(lane), lane_bytes));
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
        return false;
    }

    fn floatingPoint(self: *Cpu, ins: u32) !bool {
        _ = self;
        _ = ins;
        return false;
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
