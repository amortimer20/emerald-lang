# Spike: does a headless backend draw the same pixels twice?
Gfx.open(320, 240, false)
for frame in 0..<3 {
    Gfx.begin()
    for i in 0..<50 {
        Gfx.circle(20 + i * 5, 30 + (i * 7) % 180, 12.0, 4291559679)
        Gfx.rect(i * 6, 200, 5, 10 + i % 20, 4278255615)
    }
    Gfx.end()
}
print("checksum #{Gfx.checksum()}")
Gfx.close()
