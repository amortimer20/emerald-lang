# Display

## A type controls how it displays by adopting the prelude's `Textual` and
## supplying `to_string()`. Without it, a value keeps the field-by-field form
## that is useful while debugging.
struct Money with Textual {
    const cents: Int

    @override
    func to_string(): String {
        const whole = self.cents // 100
        const rest = (self.cents % 100).abs()
        return "$#{whole}.#{rest.to_string().pad_start(2, "0")}"
    }
}

const price = Money(1250)

## `print` and interpolation both display through the method.
print(price)
print("That will be #{price}.")

## So does every place the value appears, including inside a collection: the
## trait replaces how the value itself renders, never how a list frames it.
print([Money(399), Money(2075)])

## Calling the method directly is always available, adopted or not.
print(price.to_string())

## A type that does not adopt the trait shows its fields, which is what you
## want from a value you are still inspecting.
struct Reading {
    const sensor: String
    const value: Float
}

print(Reading("north", 21.5))

## An enum adopts it the same way, in place of its `Enum.value` default.
enum Direction with Textual {
    north
    south

    @override
    func to_string(): String {
        return case self {
            when Direction.north then "N"
            when Direction.south then "S"
        }
    }
}

print(Direction.north, [Direction.south])
