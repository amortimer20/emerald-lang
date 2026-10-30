//! Float arithmetic that must be exact where the platform shortcuts are not:
//! floored `//` and `%` (section 5.3), a correctly rounded `pow` for `**` and
//! `Math.power` (section 9.3), and decimal-place rounding (`round_to`).
//!
//! `pow` evaluates `exp(y * ln x)` in double-double arithmetic (about 100 bits),
//! so the result rounds correctly except in vanishingly rare near-tie cases. The
//! standard library's `pow` is accurate only to thousands of ulps for large
//! exponents, and the interpreter links no libc to borrow one from.

const std = @import("std");

const DD = struct {
    hi: f64,
    lo: f64,

    fn fromF64(value: f64) DD {
        return .{ .hi = value, .lo = 0 };
    }
};

fn quickTwoSum(a: f64, b: f64) DD {
    const s = a + b;
    return .{ .hi = s, .lo = b - (s - a) };
}

fn twoSum(a: f64, b: f64) DD {
    const s = a + b;
    const bb = s - a;
    return .{ .hi = s, .lo = (a - (s - bb)) + (b - bb) };
}

fn twoProd(a: f64, b: f64) DD {
    const p = a * b;
    return .{ .hi = p, .lo = @mulAdd(f64, a, b, -p) };
}

fn add(a: DD, b: DD) DD {
    const s = twoSum(a.hi, b.hi);
    const t = twoSum(a.lo, b.lo);
    var r = quickTwoSum(s.hi, s.lo + t.hi);
    r = quickTwoSum(r.hi, r.lo + t.lo);
    return r;
}

fn neg(a: DD) DD {
    return .{ .hi = -a.hi, .lo = -a.lo };
}

fn sub(a: DD, b: DD) DD {
    return add(a, neg(b));
}

fn mul(a: DD, b: DD) DD {
    const p = twoProd(a.hi, b.hi);
    return quickTwoSum(p.hi, p.lo + (a.hi * b.lo + a.lo * b.hi));
}

fn mulF64(a: DD, b: f64) DD {
    const p = twoProd(a.hi, b);
    return quickTwoSum(p.hi, p.lo + a.lo * b);
}

fn div(a: DD, b: DD) DD {
    const q1 = a.hi / b.hi;
    var r = sub(a, mulF64(b, q1));
    const q2 = r.hi / b.hi;
    r = sub(r, mulF64(b, q2));
    const q3 = r.hi / b.hi;
    const q = quickTwoSum(q1, q2);
    return add(q, DD.fromF64(q3));
}

/// ln 2 to about 106 bits.
const ln2: DD = .{ .hi = 0x1.62e42fefa39efp-1, .lo = 0x1.abc9e3b39803fp-56 };

/// exp of a double-double whose magnitude is below about 800.
fn expDD(a: DD) struct { m: DD, k: i32 } {
    const k_float = @round(a.hi / ln2.hi);
    var r = sub(a, mulF64(ln2, k_float));
    // Shrink the argument so the Taylor series converges in a few terms.
    const shrink = 512.0;
    r = .{ .hi = r.hi / shrink, .lo = r.lo / shrink };
    var term = r;
    var sum = add(DD.fromF64(1), r);
    var n: f64 = 2;
    while (n <= 12) : (n += 1) {
        term = mul(term, r);
        term = div(term, DD.fromF64(n));
        sum = add(sum, term);
    }
    // exp(r) = (exp(r/512))^512: square nine times.
    var i: usize = 0;
    while (i < 9) : (i += 1) sum = mul(sum, sum);
    return .{ .m = sum, .k = @intFromFloat(k_float) };
}

/// ln of a positive finite double as a double-double.
fn lnDD(x: f64) DD {
    const parts = std.math.frexp(x);
    var mantissa = parts.significand; // [0.5, 1)
    var exponent: i32 = parts.exponent;
    if (mantissa < std.math.sqrt1_2) {
        mantissa *= 2;
        exponent -= 1;
    }
    // One Newton step on y = ln m: y1 = y0 + (m * exp(-y0) - 1).
    const y0 = @log(mantissa);
    const e = expDD(.{ .hi = -y0, .lo = 0 });
    const scaled = mulF64(e.m, mantissa);
    const delta = sub(.{ .hi = std.math.ldexp(scaled.hi, e.k), .lo = std.math.ldexp(scaled.lo, e.k) }, DD.fromF64(1));
    const ln_m = add(DD.fromF64(y0), delta);
    return add(mulF64(ln2, @floatFromInt(exponent)), ln_m);
}

fn isOddInteger(value: f64) bool {
    if (@abs(value) >= 9007199254740992.0) return false;
    if (value != @floor(value)) return false;
    return @mod(value, 2) == 1;
}

/// `x` raised to `y`, correctly rounded for finite arguments with a finite result.
/// Special values (zero, one, NaN, infinity) follow `std.math.pow`.
pub fn power(x: f64, y: f64) f64 {
    if (y == 0 or x == 1 or y == 1 or x == 0 or !std.math.isFinite(x) or !std.math.isFinite(y)) {
        return std.math.pow(f64, x, y);
    }
    var base = x;
    var negate = false;
    if (x < 0) {
        if (y != @floor(y)) return std.math.nan(f64);
        base = -x;
        negate = isOddInteger(y);
        if (base == 1) return if (negate) -1.0 else 1.0;
    }
    const t = mulF64(lnDD(base), y);
    var result: f64 = undefined;
    if (t.hi > 710) {
        result = std.math.inf(f64);
    } else if (t.hi < -746) {
        result = 0;
    } else {
        const e = expDD(t);
        result = std.math.ldexp(e.m.hi + e.m.lo, e.k);
    }
    return if (negate) -result else result;
}

/// `a // b` for a nonzero `b`: the floor of the exact quotient, so that
/// `(a // b) * b + a % b == a`. An infinite or NaN operand uses the plain
/// quotient, which the remainder law does not constrain.
pub fn floorDivide(a: f64, b: f64) f64 {
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return @floor(a / b);
    const modulus = @rem(a, b);
    var quotient = (a - modulus) / b;
    if (modulus != 0 and (b < 0) != (modulus < 0)) quotient -= 1;
    if (quotient == 0) return std.math.copysign(@as(f64, 0), a / b);
    var floored = @floor(quotient);
    if (quotient - floored > 0.5) floored += 1;
    return floored;
}

/// `a % b` for a nonzero `b`: the result takes the divisor's sign. A NaN or
/// infinite operand produces NaN (section 5.3).
pub fn remainder(a: f64, b: f64) f64 {
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return std.math.nan(f64);
    var modulus = @rem(a, b);
    if (modulus != 0 and (b < 0) != (modulus < 0)) modulus += b;
    return modulus;
}

/// Rounds `value` to `places` decimal places, halfway values away from zero,
/// on the shortest decimal text that reads back as `value` (section 9.3). A
/// value with no digits beyond the requested place comes back unchanged.
pub fn roundTo(value: f64, places: i64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    // Binary64 spans fewer than 350 decimal places either way, so this clamp
    // changes no result and keeps `keep` below from overflowing.
    const clamped = std.math.clamp(places, -400, 400);
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{e}", .{@abs(value)}) catch return value;
    const e_index = std.mem.indexOfScalar(u8, text, 'e') orelse return value;
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    for (text[0..e_index]) |c| {
        if (c == '.') continue;
        digits[count] = c - '0';
        count += 1;
    }
    const exponent = std.fmt.parseInt(i64, text[e_index + 1 ..], 10) catch return value;
    // value = 0.d1 d2 ... dn * 10^(exponent + 1); keep this many digits.
    const keep = exponent + 1 + clamped;
    if (keep >= count) return value;
    var result_exponent = exponent;
    if (keep < 0) return std.math.copysign(@as(f64, 0), value);
    const kept: usize = @intCast(keep);
    const round_up = digits[kept] >= 5;
    var length = kept;
    if (round_up) {
        var i = kept;
        while (i > 0) {
            i -= 1;
            if (digits[i] == 9) {
                digits[i] = 0;
            } else {
                digits[i] += 1;
                break;
            }
        } else {
            // Every kept digit carried (or none were kept): the result is a 1 one place up.
            digits[0] = 1;
            length = 1;
            result_exponent += 1;
        }
    }
    if (length == 0) return std.math.copysign(@as(f64, 0), value);
    var out: [48]u8 = undefined;
    var n: usize = 0;
    for (digits[0..length]) |d| {
        out[n] = '0' + d;
        n += 1;
    }
    const rendered = std.fmt.bufPrint(out[n..], "e{d}", .{result_exponent - @as(i64, @intCast(length)) + 1}) catch return value;
    const parsed = std.fmt.parseFloat(f64, out[0 .. n + rendered.len]) catch return value;
    return std.math.copysign(parsed, value);
}

test "remainder takes the divisor's sign" {
    try std.testing.expectEqual(@as(f64, -1.0), remainder(7.0, -2.0));
    try std.testing.expectEqual(@as(f64, -0.5), remainder(7.5, -2.0));
    try std.testing.expectEqual(@as(f64, -1.0), remainder(5.0, -3.0));
    try std.testing.expectEqual(@as(f64, -2.0), remainder(0.5, -2.5));
    try std.testing.expectEqual(@as(f64, 1.0), remainder(-7.0, 2.0));
    try std.testing.expect(std.math.isNan(remainder(5.0, std.math.inf(f64))));
    try std.testing.expect(std.math.isNan(remainder(-5.0, -std.math.inf(f64))));
}

test "floor division and remainder satisfy the law" {
    try std.testing.expectEqual(@as(f64, 4.0), floorDivide(0.5, 0.1));
    try std.testing.expectEqual(@as(f64, -500001.0), floorDivide(-0.5, 1e-6));
    const cases = [_][2]f64{ .{ 7.0, -2.0 }, .{ 0.5, 0.1 }, .{ -0.5, 1e-6 }, .{ 7.5, 2.0 }, .{ -7.5, 2.0 }, .{ 1e10, 0.3 } };
    for (cases) |c| {
        const q = floorDivide(c[0], c[1]);
        const r = remainder(c[0], c[1]);
        try std.testing.expectApproxEqRel(c[0], q * c[1] + r, 1e-12);
    }
}

test "power is accurate for large exponents" {
    try std.testing.expectEqual(@as(f64, 2.4699329180060256e+41), power(1.1, 1000.0));
    try std.testing.expectEqual(@as(f64, 2.600334596395491e+267), power(1.005, 123456.789));
    try std.testing.expectEqual(@as(f64, 1024.0), power(2.0, 10.0));
    try std.testing.expectEqual(@as(f64, 1e22), power(10.0, 22.0));
    try std.testing.expectEqual(@as(f64, -8.0), power(-2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 0.5), power(2.0, -1.0));
    try std.testing.expect(std.math.isNan(power(-2.0, 0.5)));
    try std.testing.expect(std.math.isInf(power(10.0, 400.0)));
    try std.testing.expectEqual(@as(f64, 0), power(10.0, -400.0));
}

test "round_to uses decimal places and leaves large values alone" {
    try std.testing.expectEqual(@as(f64, 2.68), roundTo(2.675, 2));
    try std.testing.expectEqual(@as(f64, 1.01), roundTo(1.005, 2));
    try std.testing.expectEqual(@as(f64, 1.5), roundTo(1.45, 1));
    try std.testing.expectEqual(@as(f64, -3.0), roundTo(-2.5, 0));
    try std.testing.expectEqual(@as(f64, 1300.0), roundTo(1250.0, -2));
    try std.testing.expectEqual(@as(f64, 1000.0), roundTo(999.9, -1));
    try std.testing.expectEqual(@as(f64, 1.0), roundTo(0.96, 1));
    try std.testing.expectEqual(@as(f64, 10.0), roundTo(9.96, 1));
    try std.testing.expectEqual(@as(f64, 2247410860550237.2), roundTo(2247410860550237.2, 2));
    try std.testing.expectEqual(@as(f64, 1e300), roundTo(1e300, 5));
    try std.testing.expectEqual(@as(f64, 1e300), roundTo(1e300, -300));
    try std.testing.expectEqual(@as(f64, -28609247935418.0), roundTo(-28609247935418.004, 2));
    try std.testing.expectEqual(@as(f64, 0.0), roundTo(0.4, 0));
    try std.testing.expectEqual(@as(f64, 100.0), roundTo(60.0, -2));
    try std.testing.expectEqual(@as(f64, 0.0), roundTo(40.0, -2));
    try std.testing.expectEqual(@as(f64, 1.5), roundTo(1.5, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(f64, -0.0), roundTo(-0.001, std.math.minInt(i64)));
}
