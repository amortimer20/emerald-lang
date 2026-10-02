# Section 15.3: File.append creates a missing file, starting from empty, but not a missing folder.
const root = "emerald-append-creates-conformance"
Directory.create(root)

const log = Path.join([root, "log.txt"])
File.append(log, "first\n")
File.append(log, "second\n")
print(File.read_lines(log))

try {
    File.append(Path.join([root, "no-such-folder", "log.txt"]), "x")
}
catch error: FileError {
    print(error.message.starts_with?("could not append to"))
}

Directory.delete_recursive(root)
