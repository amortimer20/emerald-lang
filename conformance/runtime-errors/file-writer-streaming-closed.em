const writer = File.create("emerald-file-writer-streaming-closed.txt")
writer.close()
writer.close()
writer.write("no")
