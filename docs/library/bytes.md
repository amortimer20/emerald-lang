# Bytes

`Bytes` is immutable raw binary data. It preserves every octet exactly, unlike `String`, which
is always valid UTF-8. Run [`conformance/run/bytes-binary-file.em`](../../conformance/run/bytes-binary-file.em)
for construction, indexing, conversion, and streaming binary-file use.

## Construction and conversion

`Bytes.from_list(numbers: List[Int]) -> Bytes` builds bytes from integers 0 through 255 and
raises for a value outside that range. `String.to_bytes() -> Bytes` returns a string's UTF-8
encoding. `to_string() -> String` raises when the bytes are not valid UTF-8;
`to_string_maybe() -> String?` returns `nothing` instead.

## Reading and combining

`count -> Int` is the number of bytes. `bytes[index: Int] -> Int` returns one octet (0 through
255); `bytes[start..<end]` and `bytes[start..end]` return independent Bytes using the same
range-bound rules as lists. `+` joins two Bytes values. Equality and dictionary/set-key hashing
are bytewise. Printing uses a safe hexadecimal form such as `Bytes[3: 41 00 ff]`, never raw
terminal control bytes.
