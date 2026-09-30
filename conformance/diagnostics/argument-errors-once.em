trait Counter {
    var count: Int

    func bump(amount: Int) {
        self.count += amount
    }
}

class Tally with Counter {
    var count: Int = 0
}

print(Json.encode(1 + true))
print(Csv.encode(1 + true))
print(Base64.encode(1 + true))
print(Base64.decode(1 + true))
print(Base64.decode_maybe(1 + true))
print(Digest.sha256(1 + true))
print(Digest.hmac_sha256(1 + true, key: 2 + false))
print(Console.table(1 + true))
Counter.bump(1 + true, 1)
Counter.bump(Tally(), 1 + true)
