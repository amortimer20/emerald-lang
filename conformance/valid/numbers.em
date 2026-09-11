# Section 5.1 numeric forms, including the two that are easy to mislex: a dot is
# a decimal point only when a digit follows it.

var whole = 42
var separated = 1_000_000
var fraction = 3.5
var exponent = 1.5e-3
var positive_exponent = 2E+10

5.times { index => print(index) }

for number in 1..5 {
    print(number)
}

for index in 0..<10 {
    print(index)
}
