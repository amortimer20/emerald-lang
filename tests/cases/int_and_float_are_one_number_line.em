## Int and Float compare as one number line, under every operator.
##
## They did not agree until now. The four ordering operators converted, which is what
## makes 1 < 2.5 work at all, while == fell through to host equality and compared the
## boxed types first -- so 1 <= 1.0 and 1 >= 1.0 were both true and 1 == 1.0 was false.
## A reader can derive the contradiction in three lines without trying, and every
## language a student is likely to arrive from -- Python, Ruby, C#, JavaScript -- says
## the two are equal.
##
## Found by writing down what a backend would have to reproduce, which is the same way
## sort was found disagreeing with <. Two subsystems answering one question by different
## rules, in both cases.

print(1 == 1.0)
print(1 <= 1.0)
print(1 >= 1.0)
print(1 != 1.0)
print(1 < 1.0)
print(1 > 1.0)
print(1 == 2.0)
print(1 < 2.5)

## It reaches the containers, which compare elementwise with the same ==.
print([1] == [1.0])
print([1.0, 2.0].contains?(2))
print(["a": 1] == ["a": 1.0])
print([1].to_set() == [1.0].to_set())

## Only the mixed pair converts. Two Ints stay exact, because widening both to Float
## would make the two largest Ints compare equal -- one wrong answer at the edge traded
## for another.
print(9223372036854775807 == 9223372036854775806)
print(9223372036854775807 == 9223372036854775807)

## NaN is still equal to nothing, itself included. .NET's Equals says two NaNs are the
## same value; IEEE and every language a reader arrives from say they are not.
var nan = Math.sqrt(-1.0)
print(nan == nan)
print(nan != nan)

## Looking a value up in a set or a dictionary is a different question, and the checker
## refuses to ask it across types -- so the hash, which cannot be made to agree with ==
## the way a comparison can, is never consulted with the wrong kind of key. See
## err_set_membership_across_types.
