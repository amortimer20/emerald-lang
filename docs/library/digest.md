# Digest

`Digest` provides stable cryptographic digests, unlike `Hashable.hash()`, whose value is a
runtime detail and must not be stored or shown.

`Digest.sha256(bytes: Bytes) -> Bytes` returns the 32-byte SHA-256 digest. Use `to_hex()` when
printing or comparing a conventional checksum.

`Digest.hmac_sha256(bytes: Bytes, key: Bytes) -> Bytes` returns the 32-byte HMAC-SHA256 for
the message and key. Neither function is a password-hashing API; password storage needs a
dedicated password-hashing scheme, which is outside this library's scope.
