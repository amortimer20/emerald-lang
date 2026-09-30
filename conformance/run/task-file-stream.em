const path = "emerald-task-file-stream.txt"
File.write(path, "first\nsecond\n")
const file = File.open(path)
try {
    Tasks.run { tasks =>
        const first = tasks.start { => file.read_line() }
        const second = tasks.start { => file.read_line() }
        const closer = tasks.start { => file.close() }
        print(first.result().or("missing"))
        print(second.result().or("missing"))
        closer.result()
    }
    try {
        file.read()
    }
    catch error: FileError {
        print(error.message)
    }
}
finally {
    file.close()
    File.delete(path)
}
