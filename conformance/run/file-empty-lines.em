# Section 15.3: every line break ends a line, so blank lines are kept, a trailing break adds no
# extra line, and an empty file has no lines.
const root = "emerald-empty-lines-conformance"
Directory.create(root)

const cases = ["", "\n", "\n\n", "a\n\n", "a\n\nb\n", "a\n\n\n", "a\nb"]
for text in cases {
    const path = Path.join([root, "lines.txt"])
    File.write(path, text)
    print(File.read_lines(path))
}

const empty = Path.join([root, "empty.txt"])
File.write(empty, "")
const handle = File.open(empty)
print(handle.read_line())
handle.close()

Directory.delete_recursive(root)
