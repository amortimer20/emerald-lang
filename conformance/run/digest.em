# FIPS 180-4 and RFC 4231 known-answer vectors.
func repeated(value: Int, count: Int): Bytes {
    var values: List[Int] = []
    while values.count < count {
        values.append(value)
    }
    return Bytes.from_list(values)
}

print(Digest.sha256("".to_bytes()).to_hex())
print(Digest.sha256("abc".to_bytes()).to_hex())
print(Digest.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_bytes()).to_hex())

# One million `a`s, built by doubling.
var piece = "a"
var remaining = 1000000
var million = ""
while remaining > 0 {
    if remaining % 2 == 1 {
        million = million + piece
    }
    piece = piece + piece
    remaining = remaining // 2
}
print(Digest.sha256(million.to_bytes()).to_hex())

# RFC 4231 test cases 1, 2, 3, 4, 6, and 7 (5 truncates its output).
print(Digest.hmac_sha256("Hi There".to_bytes(), repeated(11, 20)).to_hex())
print(Digest.hmac_sha256(key: "Jefe".to_bytes(), bytes: "what do ya want for nothing?".to_bytes()).to_hex())
print(Digest.hmac_sha256(repeated(221, 50), repeated(170, 20)).to_hex())
var counting: List[Int] = []
while counting.count < 25 {
    counting.append(counting.count + 1)
}
print(Digest.hmac_sha256(repeated(205, 50), Bytes.from_list(counting)).to_hex())
print(Digest.hmac_sha256("Test Using Larger Than Block-Size Key - Hash Key First".to_bytes(), repeated(170, 131)).to_hex())
print(Digest.hmac_sha256("This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.".to_bytes(), repeated(170, 131)).to_hex())
