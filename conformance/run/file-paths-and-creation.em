# Section 15.3: `File.exists?` and `Directory.exists?` are mutually exclusive for real
# paths; `Directory.list` returns full paths of files and subdirectories together;
# `write_lines` writes a newline after every line; `write`, `write_binary`,
# `write_lines`, and `create` create a missing file but never a missing directory.
const root = "emerald-file-creation-conformance"
Directory.create(Path.join([root, "sub"]))
const text = Path.join([root, "text.txt"])
File.write(text, "hi")
print(File.exists?(text), Directory.exists?(text))
print(File.exists?(root), Directory.exists?(root))
const listed = Directory.list(root).sort()
print(listed)
print(listed.all? { path => path.starts_with?(root) })

const lines = Path.join([root, "lines.txt"])
File.write_lines(lines, ["one", "two"])
print(File.read(lines).bytes().count, File.read(lines) == "one\ntwo\n")

const binary = Path.join([root, "data.bin"])
File.write_binary(binary, Bytes.from_list([1, 2]))
const created = Path.join([root, "created.txt"])
const writer = File.create(created)
writer.write("made")
writer.close()
print(File.exists?(binary), File.read(created))

const missing = Path.join([root, "missing", "file.txt"])
var failures = 0
try {
    File.write(missing, "x")
}
catch error: FileError {
    failures += 1
}
try {
    File.write_binary(missing, Bytes.from_list([1]))
}
catch error: FileError {
    failures += 1
}
try {
    File.write_lines(missing, ["x"])
}
catch error: FileError {
    failures += 1
}
try {
    File.create(missing)
}
catch error: FileError {
    failures += 1
}
try {
    File.append(missing, "x")
}
catch error: FileError {
    failures += 1
}
print(failures, Directory.exists?(Path.join([root, "missing"])))
Directory.delete_recursive(root)
