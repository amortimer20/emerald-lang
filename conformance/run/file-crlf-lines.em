# File line readers agree with String.lines on Windows CRLF text.
const path = "emerald-file-crlf-lines.txt"
const text = "first\r\n\r\nlast\r\n"
File.write(path, text)
print(File.read_lines(path))
print(text.lines())

const file = File.open(path)
while true {
    const line = file.read_line()
    if line == nothing {
        break
    }
    print(line)
}
file.close()
File.delete(path)
