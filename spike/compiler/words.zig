//! Hand-lowered from benchmarks/words.em, as a Zig emitter would write it.
const rt = @import("rt.zig");
const Value = rt.Value;

fn block1(_: ?*anyopaque, entry: Value, result: *Value) callconv(.c) c_int {
    const count = entry.ptr(rt.Struct).fields[1].asInt();
    const negated = @subWithOverflow(@as(i64, 0), count);
    if (negated[1] != 0) return rt.em_fail_overflow(20);
    result.* = .int(negated[0]);
    return 0;
}

fn get(list: *rt.List, index: i64, line: c_int) error{Raised}!Value {
    var result: Value = undefined;
    if (rt.em_list_get(list, index, &result, line) != 0) return error.Raised;
    return result;
}

fn str(text: []const u8) Value {
    return .object(.string, rt.em_str_new(text.ptr, text.len));
}

fn run() error{Raised}!void {
    const words = [_][]const u8{ "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "runs" };
    var vocabulary = rt.em_list_new();
    defer rt.em_release(.object(.list, vocabulary));
    for (words) |w| rt.em_list_append(&vocabulary, str(w));
    var generator_state: i64 = 11;
    var lines = rt.em_list_new();
    defer rt.em_release(.object(.list, lines));
    const space = rt.em_str_new(" ", 1);
    defer rt.em_release(.object(.string, space));
    const newline = rt.em_str_new("\n", 1);
    defer rt.em_release(.object(.string, newline));
    var a: i64 = 0;
    while (a < 20000) : (a += 1) {
        var line = rt.em_list_new();
        defer rt.em_release(.object(.list, line));
        var b: i64 = 0;
        while (b < 12) : (b += 1) {
            const index = rt.em_random_next(&generator_state, 0, rt.em_list_count(vocabulary));
            const word = try get(vocabulary, index, 9);
            rt.em_retain(word);
            rt.em_list_append(&line, word);
        }
        rt.em_list_append(&lines, .object(.string, rt.em_list_join(line, space)));
    }
    const text = rt.em_list_join(lines, newline);
    defer rt.em_release(.object(.string, text));

    var counts = rt.em_dict_new();
    defer rt.em_release(.object(.dict, counts));
    const all = rt.em_str_words(text);
    defer rt.em_release(.object(.list, all));
    for (all.slice()) |word| {
        var found: Value = undefined;
        const current: i64 = if (rt.em_dict_get(counts, word, &found)) found.asInt() else 0;
        const next = @addWithOverflow(current, 1);
        if (next[1] != 0) {
            _ = rt.em_fail_overflow(17);
            return error.Raised;
        }
        rt.em_retain(word);
        rt.em_dict_set(&counts, word, .int(next[0]));
    }
    const entries = rt.em_dict_entries(counts);
    var top: *rt.List = undefined;
    const status = rt.em_list_sort_by(entries, block1, null, &top);
    rt.em_release(.object(.list, entries));
    if (status != 0) return error.Raised;
    defer rt.em_release(.object(.list, top));
    const pair = (try get(top, 0, 20)).ptr(rt.Struct);
    rt.em_out_str(pair.fields[0].ptr(rt.Str));
    rt.em_out_sep();
    rt.em_out_int(pair.fields[1].asInt());
    rt.em_out_sep();
    rt.em_out_int(rt.em_dict_count(counts));
    rt.em_out_newline();
}

pub fn main() u8 {
    run() catch return @intCast(rt.em_report());
    rt.em_flush();
    return 0;
}
