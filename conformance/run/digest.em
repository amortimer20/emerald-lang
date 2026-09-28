# FIPS 180-4 and RFC 4231 known-answer vectors.
print(Digest.sha256("".to_bytes()).to_hex())
print(Digest.sha256("abc".to_bytes()).to_hex())
print(Digest.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_bytes()).to_hex())
print(Digest.hmac_sha256("Hi There".to_bytes(), Bytes.from_list([11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11])).to_hex())
print(Digest.hmac_sha256("what do ya want for nothing?".to_bytes(), "Jefe".to_bytes()).to_hex())
