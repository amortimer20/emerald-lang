# Section 11.5 across a project: a type in `shop/` registers arithmetic and
# adopts `Ordered`, and the entry file uses its operators through `using`.

using Shop

const basket = [Price(250), Price(120), Price(399)]
var total = Price(0)
var cheapest = basket[0]
for price in basket {
    total += price
    if price < cheapest {
        cheapest = price
    }
}
print(total.cents, cheapest.cents)
