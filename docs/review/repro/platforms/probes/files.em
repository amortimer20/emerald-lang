# Probe: Path operations, Directory.list order, line endings, BOM.
const ps = ["a/b/c.txt", "a\\b\\c.txt", "C:\\x\\y.txt", "C:/x/y.txt", "/abs/p", "\\\\server\\share\\f.txt", "rel", "", "/", "a/b/", "a//b", ".hidden", "a.tar.gz", "dir.d/file", "c:", "a\\b/c.d\\e"]
for p in ps {
    print("[" + p + "] name=" + Path.name(p) + " stem=" + Path.stem(p) + " ext=" + Path.extension(p) + " parent=" + Path.parent(p) + " abs?=" + Path.absolute?(p).to_string())
}
print(Path.join(["a", "b", "c"]), Path.join(["a/", "/b"]), Path.join(["C:\\x", "y"]), Path.join(["", "a", ""]), Path.join(["/", "a"]))
const root = "emerald-platform-probe"
Directory.delete_recursive(root)
Directory.create(root)
for name in ["b.txt", "a.txt", "C.txt", "é.txt", "e\u{0301}x.txt", "10.txt", "9.txt", "Z", "_"] {
    File.write(Path.join([root, name]), name)
}
print(Directory.list(root))
print(Directory.list(root).sort())
File.write_binary(Path.join([root, "crlf.txt"]), Bytes.from_list([111, 110, 101, 13, 10, 116, 119, 111, 13, 10, 13, 10, 108, 97, 115, 116, 13]))
print(File.read_lines(Path.join([root, "crlf.txt"])))
print(File.read(Path.join([root, "crlf.txt"])).count, File.read(Path.join([root, "crlf.txt"])).code_points())
print(File.read(Path.join([root, "crlf.txt"])).lines())
const handle = File.open(Path.join([root, "crlf.txt"]))
var line = handle.read_line()
while line != nothing {
    print(line.code_points())
    line = handle.read_line()
}
handle.close()
File.write_binary(Path.join([root, "bom.txt"]), Bytes.from_list([239, 187, 191, 104, 105, 10, 120]))
print(File.read(Path.join([root, "bom.txt"])).code_points(), File.read_lines(Path.join([root, "bom.txt"])))
File.write(Path.join([root, "w.txt"]), "x\ny\n")
File.write_lines(Path.join([root, "wl.txt"]), ["p", "q"])
print(File.read_binary(Path.join([root, "w.txt"])).count, File.read_binary(Path.join([root, "wl.txt"])).count)
print(Path.absolute(root).ends_with?(root), Path.absolute?(Path.absolute(root)), Path.absolute(root).contains?("\\"))
Directory.delete_recursive(root)
