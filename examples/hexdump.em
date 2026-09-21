## Try it
##
##   zig build run -- run examples/hexdump.em -- path/to/file
##
## Reads the file incrementally, so it remains useful for large binary files.

const printable_ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
const arguments = Program.arguments

if arguments.empty?() {
    print("Usage: emerald run examples/hexdump.em -- FILE")
    return
}

var file = File.open(arguments[0])
var offset = 0
while true {
    const chunk = file.read_bytes(16)
    if chunk == nothing {
        break
    }
    var hex = ""
    var ascii = ""
    for index in 0..<chunk.count {
        const byte = chunk[index]
        hex += byte.to_string(base: 16).pad_start(2, "0")
        if index + 1 < chunk.count {
            hex += " "
        }
        if byte.between?(32, 126) {
            ascii += printable_ascii[byte - 32]
        } else {
            ascii += "."
        }
    }
    print("#{offset.to_string(base: 16).pad_start(8, "0")}  #{hex}  |#{ascii}|")
    offset += chunk.count
}
file.close()
