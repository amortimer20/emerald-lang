print(random(1))
print([1].shuffle(2))
const frozen = [1, 2]
frozen.shuffle!()
const source = Random(seed: 1)
print(source.next(1))
print(source.choose("text"))
source.shuffle!(frozen)
