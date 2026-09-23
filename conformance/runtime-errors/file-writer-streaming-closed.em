const path = "emerald-file-writer-streaming-closed.txt"
const writer = File.create(path)
try {
    writer.close()
    writer.close()
    writer.write("no")
} finally {
    File.delete(path)
}
