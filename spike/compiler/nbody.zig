//! Hand-lowered from benchmarks/nbody.em, as a Zig emitter would write it,
//! on the same erased heap structs as nbody.c.
const rt = @import("rt.zig");
const Value = rt.Value;

const x = 0;
const y = 1;
const vx = 2;
const vy = 3;
const mass = 4;

fn body(a: f64, b: f64, c: f64, d: f64, e: f64) Value {
    const fields = [5]Value{ .float(a), .float(b), .float(c), .float(d), .float(e) };
    return .object(.structure, rt.em_struct_new(5, &fields));
}

fn field(v: Value, index: usize) f64 {
    return v.ptr(rt.Struct).fields[index].asFloat();
}

fn get(list: *rt.List, index: i64, line: c_int) error{Raised}!Value {
    var result: Value = undefined;
    if (rt.em_list_get(list, index, &result, line) != 0) return error.Raised;
    return result;
}

fn forWrite(slot: **rt.List, index: i64, line: c_int) error{Raised}!*rt.Struct {
    var result: *rt.Struct = undefined;
    if (rt.em_list_struct_for_write(slot, index, &result, line) != 0) return error.Raised;
    return result;
}

fn run(bodies: **rt.List) error{Raised}!void {
    var step: i64 = 1;
    while (step <= 8000) : (step += 1) {
        const n1 = rt.em_list_count(bodies.*);
        var i: i64 = 0;
        while (i < n1) : (i += 1) {
            var ax: f64 = 0.0;
            var ay: f64 = 0.0;
            const n2 = rt.em_list_count(bodies.*);
            var j: i64 = 0;
            while (j < n2) : (j += 1) {
                if (i == j) continue;
                const bj = try get(bodies.*, j, 27);
                const bi = try get(bodies.*, i, 27);
                const dx = field(bj, x) - field(bi, x);
                const dy = field(bj, y) - field(bi, y);
                const distance = @sqrt(dx * dx + dy * dy + 0.01);
                const pull = field(bj, mass) / (distance * distance * distance);
                ax += dx * pull;
                ay += dy * pull;
            }
            var b = try forWrite(bodies, i, 34);
            b.fields[vx] = .float(b.fields[vx].asFloat() + ax * 0.01);
            b = try forWrite(bodies, i, 35);
            b.fields[vy] = .float(b.fields[vy].asFloat() + ay * 0.01);
        }
        const n3 = rt.em_list_count(bodies.*);
        i = 0;
        while (i < n3) : (i += 1) {
            var b = try forWrite(bodies, i, 38);
            b.fields[x] = .float(b.fields[x].asFloat() + b.fields[vx].asFloat() * 0.01);
            b = try forWrite(bodies, i, 39);
            b.fields[y] = .float(b.fields[y].asFloat() + b.fields[vy].asFloat() * 0.01);
        }
    }
    const b1 = try get(bodies.*, 1, 42);
    rt.em_out_float(rt.em_float_round_to(field(b1, x), 3));
    rt.em_out_sep();
    rt.em_out_float(rt.em_float_round_to(field(b1, y), 3));
    rt.em_out_newline();
}

pub fn main() u8 {
    var bodies = rt.em_list_new();
    defer rt.em_release(.object(.list, bodies));
    rt.em_list_append(&bodies, body(0.0, 0.0, 0.0, 0.0, 1000.0));
    rt.em_list_append(&bodies, body(100.0, 0.0, 0.0, 3.0, 1.0));
    rt.em_list_append(&bodies, body(-150.0, 0.0, 0.0, -2.5, 1.0));
    rt.em_list_append(&bodies, body(0.0, 200.0, -2.2, 0.0, 1.0));
    rt.em_list_append(&bodies, body(0.0, -250.0, 2.0, 0.0, 1.0));
    run(&bodies) catch return @intCast(rt.em_report());
    rt.em_flush();
    return 0;
}
