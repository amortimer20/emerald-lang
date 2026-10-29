# strings.characters has no errdefer for its list, so a failed append leaks
# it. Reached here through Base64 decoding and Bytes.from_hex.
print(Base64.decode("aGVsbG8gd29ybGQ=").to_hex())
print(Bytes.from_hex("68656c6c6f"))
