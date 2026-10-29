# Probe: seeded Random sequences.
for seed in [0, 1, 42, -1, 9223372036854775807, -9223372036854775808] {
    const r = Random(seed: seed)
    var out: List[String] = []
    for i in 0..20 {
        out.append(r.next(1..1000000).to_string())
        out.append(r.next_fraction().to_string())
    }
    out.append(r.next(-9223372036854775808..9223372036854775807).to_string())
    var l = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    r.shuffle!(l)
    out.append("#{l}")
    out.append(r.choose(["a", "b", "c", "d"]).or("-"))
    print(seed, out.join(" "))
}
