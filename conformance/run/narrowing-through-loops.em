# What a loop body does not undo, it keeps.
var line: String? = "first"
var count = 0
while line != nothing {
    print(line.upper())
    count += 1
    if count < 3 {
        line = "again"
    }
    else {
        line = nothing
    }
}

const limit: Int? = 3
if limit != nothing {
    for step in 1..2 {
        print(limit + step)
    }
}

# A body that assigns a value that is certainly there proves it again.
var latest: Int? = nothing
for step in 1..2 {
    latest = step * 10
    print(latest + 1)
}
