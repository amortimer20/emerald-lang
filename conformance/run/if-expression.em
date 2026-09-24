# Section 6.2: both answers are checked, but only the selected one runs.
var score = 14
var label = if score >= 10 then "winner" else "playing"
print(label)
print(if false then "wrong" else "right")

func traced_condition(): Bool {
    print("condition")
    return true
}

func traced_answer(value: Int): Int {
    print("answer #{value}")
    return value
}

print(if traced_condition() then traced_answer(1) else traced_answer(2))
print(if false then traced_answer(3) else traced_answer(4))
print(if true then 5 else 1 // 0)
print(if false then 1 // 0 else 6)

# Arithmetic stays in its answer; parentheses apply it to the whole choice.
print(if true then 1 + 2 else 3 * 4)
print((if false then 1 else 2) * 3)
print((if true then "abc" else "d").count)
print([10, 20][if true then 0 else 1])
print("#{if score >= 10 then "high" else "low"}")
print(if true then if false then 1 else 2 else 3)
print(if false then 1 else if true then 2 else 3)
print(if (if true then false else true) then 1 else 2)

# Numeric widening, optional results, and narrowing in either answer.
const number = if true then 1 else 2.5
print(number.type_name, number)
const missing = if false then "present" else nothing
print(missing.or("absent"))
func describe(value: Int?): Int {
    return if value == nothing then -1 else value + 1
}
func doubled(value: Int?): Int {
    return if value != nothing then value * 2 else 0
}
print(describe(nothing), describe(4), doubled(3))

# Context flows into collection and lambda answers.
const numbers: List[Int] = if true then [] else [1]
const increment: func(Int): Int = if true then { n => n + 1 } else { n => n - 1 }
print(numbers.count, increment(4))
print([1, 2, 3].map { n => if n > 1 then n * 10 else n })

# Sibling classes infer a shared base, just as value-producing case does.
class Animal {
}
class Dog extends Animal {
    const tricks: Int = 2
}
class Cat extends Animal {
}
const pet = if true then Dog() else Cat()
print(tricks(pet))
func tricks(pet: Animal): Int {
    return if pet is Dog then pet.tricks else 0
}
print(tricks(Dog()), tricks(Cat()))

# Branches can contain case expressions and can themselves appear in headers.
print(if true then case 1 {
    when 1 then "one"
    else then "other"
} else "skipped")
if if true then false else true {
    print("wrong")
}
else {
    print("header")
}
