# Section 15.3: text written to a FileWriter is visible to any read of the file as soon as
# `write` returns, before `close`.
const path = "emerald-writer-visibility-conformance.txt"
const writer = File.create(path)
writer.write("live")
print("[" + File.read(path) + "]")
writer.close()
File.delete(path)
