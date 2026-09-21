# Section 13.3: FileHandle reads UTF-8 text incrementally and with_open closes
# it on every exit from its block.
const path = "emerald-file-streaming-conformance.txt"
File.write(path, "one\ntwo\nthree")

var partial = File.open(path)
print(partial.read_line())
print(partial.read())
partial.close()
partial.close()

var file = File.open(path)
while true {
    const line = file.read_line()
    if line == nothing {
        break
    }
    print(line)
}
file.close()

File.with_open(path) { opened =>
    print(opened.read_line())
}

try {
    File.with_open(path) { opened =>
        print(opened.read_line())
        raise AssertionError("stop here")
    }
}
catch error {
    print(error.message)
}

File.with_open(path) { reopened =>
    print(reopened.read_line())
}

File.delete(path)
