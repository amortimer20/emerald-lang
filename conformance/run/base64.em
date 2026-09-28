# RFC 4648 section 10, in the standard padded and URL-safe unpadded forms.
const texts = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
texts.each { text =>
    print(Base64.encode(text.to_bytes()))
    print(Base64.decode(Base64.encode(text.to_bytes())).to_string())
    print(Base64.encode(text.to_bytes(), url_safe: true))
    print(Base64.decode(Base64.encode(text.to_bytes(), url_safe: true), url_safe: true).to_string())
}

print(Base64.decode("Zm9v\nYmFy").to_string())
print(Base64.decode_maybe("%") == nothing)

try {
    Base64.decode("A")
} catch error: EncodingError {
    print(error.message)
}
try {
    Base64.decode("Zm9v=YmFy")
} catch error: EncodingError {
    print(error.message)
}
try {
    Base64.decode("Zm9v-")
} catch error: EncodingError {
    print(error.message)
}
try {
    Base64.decode("ZgB")
} catch error: EncodingError {
    print(error.message)
}
