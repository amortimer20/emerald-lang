# Structs and Float arithmetic: bodies pulling on each other, step by step.

struct Body {
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    const mass: Float
}

var bodies = [
    Body(0.0, 0.0, 0.0, 0.0, 1000.0),
    Body(100.0, 0.0, 0.0, 3.0, 1.0),
    Body(-150.0, 0.0, 0.0, -2.5, 1.0),
    Body(0.0, 200.0, -2.2, 0.0, 1.0),
    Body(0.0, -250.0, 2.0, 0.0, 1.0),
]

for _ in 1..8000 {
    for i in 0..<bodies.count {
        var ax = 0.0
        var ay = 0.0
        for j in 0..<bodies.count {
            if i == j {
                continue
            }
            const dx = bodies[j].x - bodies[i].x
            const dy = bodies[j].y - bodies[i].y
            const distance = (dx * dx + dy * dy + 0.01).square_root()
            const pull = bodies[j].mass / (distance * distance * distance)
            ax += dx * pull
            ay += dy * pull
        }
        bodies[i].vx += ax * 0.01
        bodies[i].vy += ay * 0.01
    }
    for i in 0..<bodies.count {
        bodies[i].x += bodies[i].vx * 0.01
        bodies[i].y += bodies[i].vy * 0.01
    }
}
print(bodies[1].x.round_to(3), bodies[1].y.round_to(3))
