# Finding P2. Path.absolute returns the host's separators, and Path.join
# appends with "/", so on Windows a joined absolute path mixes both.
File.write("probe-absolute.txt", "x")
const joined = Path.join([Path.absolute("probe-absolute.txt"), "child"])
print(joined.contains?("\\"), joined.contains?("/"))
File.delete("probe-absolute.txt")
