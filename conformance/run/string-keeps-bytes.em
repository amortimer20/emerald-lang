# Section 9.2: a `String` keeps exactly the bytes it was built from; reading a file
# and writing it back reproduces them, though equality is canonical.
const root = "emerald-string-bytes-conformance"
Directory.create(root)
const path = Path.join([root, "name.txt"])
const decomposed = "cafe\u{301}"
File.write(path, decomposed)
const text = File.read(path)
print(text == "caf\u{e9}", text.bytes())
const copy = Path.join([root, "copy.txt"])
File.write(copy, text)
print(File.read_binary(copy) == File.read_binary(path), File.read_binary(copy).count)
Directory.delete_recursive(root)
