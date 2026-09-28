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

# Each malformed text, and the index its message names.
const malformed = ["A", "Zm9v=YmFy", "Zm9v-", "ZgB", "ZgB=", "Zm9v\u{e9}", "Zg=", "Zm9v===", "Zm9v="]
for text in malformed {
    try {
        Base64.decode(text)
    }
    catch error: EncodingError {
        print(error.message)
    }
}

try {
    Base64.decode("Zm9v+", url_safe: true)
}
catch error: EncodingError {
    print(error.message)
}
print(Base64.decode("Zm9v\r\nYmFy\n").to_string())
print(Base64.decode("  Zg==  ").to_string())
