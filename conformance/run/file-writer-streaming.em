# Section 13.3: FileWriter streams UTF-8 text, and with_writer closes on
# normal completion and an error.
const path = "emerald-file-writer-streaming-conformance.txt"

var writer = File.create(path)
writer.write("one")
writer.write(" two")
writer.close()
writer.close()
print(File.read(path))

File.with_writer(path) { opened =>
    opened.write("three")
}
print(File.read(path))

try {
    File.with_writer(path) { opened =>
        opened.write("four")
        raise AssertionError("stop here")
    }
}
catch error {
    print(error.message)
}
print(File.read(path))

File.delete(path)
