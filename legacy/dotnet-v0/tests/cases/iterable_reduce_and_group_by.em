## The last two methods, each needing something the inference did not have.
##
## reduce's R sits in a block parameter rather than in what the block returns, so the
## block cannot be typed until R is known and R cannot be read off the block. reduce(0)
## breaks the cycle: an ordinary argument settles R before the block is looked at.
##
## group_by answers Dictionary<K, List<Item>>, and asking whether K can be hashed inside
## the trait gets "a dictionary cannot be keyed by K" — true and useless, because K is
## nobody's answer there. The rule waits, and then actually runs once the call says what
## K is, which the case next door proves.

class Deck with Iterable {
    type Item = Int

    func each(step: func(Int)) {
        step(1)
        step(2)
        step(3)
        step(4)
    }
}

var deck = Deck()
var list = [1, 2, 3, 4]

print("#{deck.reduce(0) { acc, n => acc + n }} #{list.reduce(0) { acc, n => acc + n }}")
print("#{deck.reduce("") { acc, n => acc + "#{n}" }} #{list.reduce("") { acc, n => acc + "#{n}" }}")
print("#{deck.group_by { n => n.even?() }}")
print("#{list.group_by { n => n.even?() }}")

## The answers are real types rather than placeholders, which is what makes them usable
## anywhere but straight into another call. map's own R was never substituted until the
## same pass fixed it — `deck.map { n => n * 2 }` typed as List<R> and could be assigned
## to neither List<Int> nor List<String>, so nothing ever caught it.
var total: Int = deck.reduce(0) { acc, n => acc + n }
var joined: String = deck.reduce("") { acc, n => acc + "#{n}" }
var doubled: List<Int> = deck.map { n => n * 2 }
var by_parity: Dictionary<Bool, List<Int>> = deck.group_by { n => n.even?() }

print("#{total} #{joined}")
print(doubled.join(", "))
print(by_parity[true].or([]).join(", "))
