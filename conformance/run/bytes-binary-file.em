const path = "emerald-bytes-binary-conformance.bin"
const output = "emerald-bytes-binary-output.bin"
const bytes = Bytes.from_list([65, 0, 255])

print(bytes)
print(bytes.count)
print(bytes[2])
print((bytes[0..<1] + "B".to_bytes()).to_string())
print(bytes.to_string_maybe() == nothing)

File.write_binary(path, bytes)
var reader = File.open(path)
print(reader.read_bytes(2))
print(reader.read_all_bytes())
print(reader.read_bytes(1) == nothing)
reader.close()

var writer = File.create(output)
writer.write_bytes(Bytes.from_list([79, 75]))
writer.close()
print(File.read_binary(output).to_string())

File.delete(path)
File.delete(output)
