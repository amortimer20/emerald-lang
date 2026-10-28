# A beginner's game loop: Conway's Game of Life on a grid of lists, one frame
# at a time, the shape a text or graphics game takes.

const size = 40
var grid = [[false].repeat(size)].repeat(size)
const generator = Random(3)
for row in 0..<size {
    for column in 0..<size {
        grid[row][column] = generator.next(0..3) == 0
    }
}

for _ in 0..<40 {
    var next = [[false].repeat(size)].repeat(size)
    for row in 0..<size {
        for column in 0..<size {
            var neighbors = 0
            for dr in -1..1 {
                for dc in -1..1 {
                    if dr == 0 and dc == 0 {
                        continue
                    }
                    const r = (row + dr + size) % size
                    const c = (column + dc + size) % size
                    if grid[r][c] {
                        neighbors += 1
                    }
                }
            }
            next[row][column] = neighbors == 3 or grid[row][column] and neighbors == 2
        }
    }
    grid = next
}
print(grid.map { row => row.count_where { alive => alive } }.sum())
