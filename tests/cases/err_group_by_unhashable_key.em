## The half of deferred key checking that makes the other half safe.
##
## Inside the trait, group_by's Dictionary<K, ...> cannot be asked whether K hashes, so the
## key rule lets a bare type parameter through. If it stopped there, this would build a
## dictionary keyed by a list — identity-hashed, so two equal lists would be two different
## keys, which is the exact hole §3.7's key rules exist to close. The rule waits; it does
## not go away.

class Deck with Iterable {
    type Item = Int

    func each(step: func(Int)) {
        step(1)
        step(2)
    }
}

print(Deck().group_by { n => [n] })
