## Try it: emerald run examples/encoding.em

const encoded = Base64.encode("Ada Lovelace".to_bytes())
print(encoded)
print(Base64.decode(encoded).to_string())
print(Digest.sha256("hello".to_bytes()).to_hex())
print(Digest.hmac_sha256("message".to_bytes(), "secret".to_bytes()).to_hex())
