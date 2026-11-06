# Spike benchmark: what the interpreter sustains per frame.
# Run: emerald run spike/bench/frames.em -- <mode> <frames> <shapes> <entities>
# mode: draw (window, update, draw), update (no window), calls (window, draw only)
class Entity {
    var x: Float
    var y: Float
    var dx: Float
    var dy: Float

    constructor(x: Float, y: Float, dx: Float, dy: Float) {
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
    }
}

const args = Program.arguments
const mode = args[0]
const frames = args[1].to_int()
const shapes = args[2].to_int()
const count = args[3].to_int()

var entities: List[Entity] = []
for i in 0..<count {
    entities.append(Entity(((i * 37) % 780).to_float(), ((i * 91) % 580).to_float(), 1.5 + (i % 5).to_float(), 1.0 + (i % 3).to_float()))
}

func step() {
    entities.each { e =>
        e.x += e.dx
        e.y += e.dy
        if e.x < 0.0 or e.x > 790.0 { e.dx = -e.dx }
        if e.y < 0.0 or e.y > 590.0 { e.dy = -e.dy }
    }
}

const window = mode != "update" and mode != "dry"
if window { Gfx.open(800, 600, false) }
const watch = Stopwatch.start()
for frame in 0..<frames {
    if mode != "calls" { step() }
    if mode == "dry" {
        var sink = 0
        for s in 0..<shapes {
            const e = entities[s % count]
            sink += e.x.to_int() + e.y.to_int()
        }
    }
    if window {
        Gfx.begin()
        for s in 0..<shapes {
            const e = entities[s % count]
            Gfx.circle(e.x.to_int(), e.y.to_int(), 3.0, 4291559679)
        }
        Gfx.end()
    }
}
const seconds = watch.elapsed().total_seconds
if window { Gfx.close() }
print("#{mode}: #{frames} frames, #{shapes} shapes, #{count} entities: #{(frames.to_float() / seconds).round_to(1)} frames/s, #{(seconds * 1000.0 / frames.to_float()).round_to(2)} ms/frame")
