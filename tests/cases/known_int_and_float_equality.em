## KNOWN HOLE. The output below is what Emerald does today, and two of these lines
## contradict each other. Recorded rather than fixed, because which way it should be
## fixed is a language decision.
##
## The comparison operators treat Int and Float as one number line: 1 <= 1.0 and
## 1 >= 1.0 are both true, which is what anyone would expect from 1 < 2.5 working.
## Equality does not: it compares type-strictly, so 1 == 1.0 is false.
##
## Those cannot both be right. In any ordering a reader has ever met, x <= y and
## x >= y together mean x == y, and a student can derive the contradiction in three
## lines without trying. It is the same shape as sort disagreeing with < -- two
## subsystems answering one question by different rules -- and it was found the same
## way, by writing down what the backend would have to reproduce.
##
## Three ways out, and they are not equivalent:
##
##   Make == numeric, so 1 == 1.0 is true. What Python, Ruby, C# and JavaScript all
##   do. Costs the property that == never crosses a type boundary.
##
##   Make a mixed comparison a checker error, so neither line exists. Keeps both rules
##   honest by making the question unaskable, and is the most static answer.
##
##   Leave it. Not defensible once written down.

print(1 == 1.0)
print(1 <= 1.0)
print(1 >= 1.0)
print(1 < 1.0)
print(1 > 1.0)

## It reaches the containers too, since they compare elementwise with the same ==.
print([1] == [1.0])
print([1.0, 2.0].contains?(2))
