## A predicate has to answer yes or no.
##
## Without this a block giving back anything at all was accepted and then read for
## truthiness, so `filter { x => x.even? }` -- the method itself rather than its answer --
## kept every element instead of the even ones, all? said true, find returned the first
## item and reject gave back nothing. Four plausible wrong answers from one missing pair
## of parentheses, and a plausible wrong answer is worse than an error.
##
## Made possible by §3.1: a member read names a method rather than calling it, which is
## what makes callbacks work and what puts a callable one keystroke from every predicate.
var numbers = [5, 3, 8]

print(numbers.filter { x => x.even? })
