## Answering an associated type differently obliges you to answer the methods that hand
## one back. A trait's own filter builds a List<Item> and can build nothing else — it
## cannot construct whatever implements it — so inheriting that body after saying
## `type Filtered = Set<Int>` is typed Set and evaluates to a List.
##
## Measured rather than reasoned: before this check existed it printed "checker says Set,
## runtime says List". The alternative was a builder protocol every implementer has to
## satisfy, which buys one override instead of four and costs a whole second contract —
## declined until something actually wants to preserve its own shape.

class Odd with Iterable {
    type Item = Int
    type Filtered = Set<Int>

    func each(step: func(Int)) {
        step(1)
        step(2)
    }
}

print(Odd().filter { n => n > 1 }.type_name())
