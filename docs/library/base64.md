# Base64

`Base64` converts immutable `Bytes` to and from RFC 4648 text. Run
[`examples/encoding.em`](../../examples/encoding.em) for a complete example.

`Base64.encode(bytes: Bytes, url_safe: Bool = false) -> String` uses the standard `+` and `/`
alphabet with padding. With `url_safe: true`, it uses `-` and `_` and omits padding.
`Base64.decode(text: String, url_safe: Bool = false) -> Bytes` accepts either padded or
unpadded input and ignores spaces, tabs, and line breaks. The `_maybe` form returns `nothing`
instead of raising. **Raises** `EncodingError` for an invalid character, alphabet, padding,
length, or non-zero trailing bits.
