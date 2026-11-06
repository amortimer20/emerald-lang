//! Spike: the smallest C-ABI module over raylib, to measure the interpreter's
//! per-call cost and the module's size. Not the design: see
//! docs/vendor-libraries-design-plan.md, slice 0.
const Color = extern struct { r: u8, g: u8, b: u8, a: u8 };

extern fn InitWindow(width: c_int, height: c_int, title: [*:0]const u8) void;
extern fn CloseWindow() void;
extern fn WindowShouldClose() bool;
extern fn BeginDrawing() void;
extern fn EndDrawing() void;
extern fn ClearBackground(color: Color) void;
extern fn DrawCircle(x: c_int, y: c_int, radius: f32, color: Color) void;
extern fn DrawRectangle(x: c_int, y: c_int, w: c_int, h: c_int, color: Color) void;
extern fn SetTargetFPS(fps: c_int) void;
extern fn SetConfigFlags(flags: c_uint) void;
extern fn GetFPS() c_int;
extern fn SetTraceLogLevel(level: c_int) void;

fn color(rgba: u32) Color {
    return .{ .r = @truncate(rgba >> 24), .g = @truncate(rgba >> 16), .b = @truncate(rgba >> 8), .a = @truncate(rgba) };
}

export fn spike_open(width: i64, height: i64, vsync: bool) bool {
    SetTraceLogLevel(7);
    if (vsync) SetConfigFlags(0x40);
    InitWindow(@intCast(width), @intCast(height), "Emerald spike");
    SetTargetFPS(0);
    return true;
}
export fn spike_close() void {
    CloseWindow();
}
export fn spike_should_close() bool {
    return WindowShouldClose();
}
export fn spike_begin() void {
    BeginDrawing();
    ClearBackground(color(0x101820ff));
}
export fn spike_end() void {
    EndDrawing();
}
export fn spike_circle(x: i64, y: i64, radius: f64, rgba: i64) void {
    DrawCircle(@intCast(x), @intCast(y), @floatCast(radius), color(@intCast(rgba)));
}
export fn spike_rect(x: i64, y: i64, w: i64, h: i64, rgba: i64) void {
    DrawRectangle(@intCast(x), @intCast(y), @intCast(w), @intCast(h), color(@intCast(rgba)));
}
export fn spike_fps() i64 {
    return GetFPS();
}
