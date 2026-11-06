//! Hand-lowered from benchmarks/fib.em, as a Zig emitter would write it.
const rt = @import("rt.zig");

fn fib(n: i64) error{Raised}!i64 {
    if (n < 2) return n;
    const t1 = @subWithOverflow(n, 1);
    if (t1[1] != 0) return raise(7);
    const t2 = try fib(t1[0]);
    const t3 = @subWithOverflow(n, 2);
    if (t3[1] != 0) return raise(7);
    const t4 = try fib(t3[0]);
    const t5 = @addWithOverflow(t2, t4);
    if (t5[1] != 0) return raise(7);
    return t5[0];
}

fn raise(line: c_int) error{Raised} {
    _ = rt.em_fail_overflow(line);
    return error.Raised;
}

pub fn main() u8 {
    const result = fib(27) catch return @intCast(rt.em_report());
    rt.em_out_int(result);
    rt.em_out_newline();
    rt.em_flush();
    return 0;
}
