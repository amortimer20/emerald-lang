# Hex makes raw bytes portable text without making them Strings. Every octet
# round-trips, and invalid input remains a catchable EncodingError.
print(Bytes.from_hex("").to_hex())
print(Bytes.from_hex("0aFF").to_hex())
print(Bytes.from_hex_maybe("0") == nothing)
print(Bytes.from_hex_maybe("0g") == nothing)

var values: List[Int] = []
var number = 0
while number <= 255 {
    values.append(number)
    number += 1
}
const every_byte = Bytes.from_list(values)
print(Bytes.from_hex(every_byte.to_hex()) == every_byte)

try {
    Bytes.from_hex("0123456")
} catch error: EncodingError {
    print(error.message)
}

try {
    Bytes.from_hex("01234g")
} catch error: EncodingError {
    print(error.message)
}

try {
    Bytes.from_list([255]).to_string()
} catch error: EncodingError {
    print(error.message)
}
