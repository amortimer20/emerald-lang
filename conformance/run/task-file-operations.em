class Progress {
    var happened: Bool = false
}
const progress = Progress()
const directory = "emerald-task-file-operations"
try {
    Tasks.run { tasks =>
        const work = tasks.start { =>
            Directory.create(directory)
            assert(progress.happened)
            const path = Path.join([directory, "data.txt"])
            File.write(path, "a")
            File.append(path, "b")
            assert(File.read(path) == "ab")
            assert(File.exists?(path))
            assert(Directory.exists?(directory))
            assert(Path.absolute?(Path.absolute(path)))
            const copy = Path.join([directory, "copy.txt"])
            const moved = Path.join([directory, "moved.txt"])
            File.copy(path, copy)
            File.move(copy, moved)
            assert(Directory.list(directory).count == 2)
            File.write_binary(moved, "bytes".to_bytes())
            assert(File.read_binary(moved).to_string() == "bytes")
            File.with_writer(path) { writer =>
                writer.write("first\n")
                writer.write_bytes("second\n".to_bytes())
            }
            assert(File.read_lines(path) == ["first", "second"])
            File.write_lines(moved, ["third"])
            assert(File.read_lines(moved) == ["third"])
            File.delete(path)
            File.delete(moved)
            Directory.delete(directory)
            return "file operations passed"
        }
        tasks.start { => progress.happened = true }
        print(work.result())
    }
}
finally {
    Directory.delete_recursive(directory)
}
