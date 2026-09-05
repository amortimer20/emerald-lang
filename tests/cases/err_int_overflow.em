## An Int that will not hold the answer says so, rather than wrapping to a negative one.
## ** already reported overflow and + - * did not, so the largest number in the language
## behaved one way under one operator and another way under the rest.
var big = 9223372036854775807
print(big + 1)
