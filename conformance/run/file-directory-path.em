# Section 15.3: whole-file text operations, recursive directories, and lexical paths.
const root = "emerald-file-api-conformance"
const nested = Path.join([root, "one", "two"])
Directory.create(nested)
Directory.create(nested)

const first = Path.join([nested, "notes.txt"])
File.write(first, "first")
File.append(first, " line")
print(File.read(first))

const lines = Path.join([nested, "lines.txt"])
File.write_lines(lines, ["one", "two"])
print(File.read_lines(lines))
print(File.exists?(first), Directory.exists?(nested))

const copied = Path.join([nested, "copy.txt"])
File.copy(first, copied)
const moved = Path.join([nested, "moved.txt"])
File.move(copied, moved)
print(File.exists?(copied), File.exists?(moved))
print(Path.name(first) + "|" + Path.stem(first) + "|" + Path.extension(first) + "|" + Path.parent("notes.txt"))
print(Path.absolute?(first), Path.absolute(first).ends_with?("notes.txt"))
assert Directory.list(nested).count == 3

File.delete(first)
File.delete(lines)
File.delete(moved)
Directory.delete(nested)
Directory.delete(Path.parent(nested))
Directory.delete(root)
