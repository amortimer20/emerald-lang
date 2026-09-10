## A block's parameter count picks the overload, and the value it evaluates to agrees
## with the type the call was checked as having.
##
## This used to be unsound. The checker resolved to run_it(func(Int): Int), which gives
## back a String, and accepted `var answer: String`. The interpreter's own matcher did
## not discriminate on how many parameters a block takes, called run_it(func(): Int), and
## put an Int in a variable declared String -- which then printed as 1 and failed at
## whatever first treated it as text.
##
## Fixed by the checker recording which declaration each call resolved to, and the
## interpreter invoking that one rather than choosing again.

func run_it(g: func(): Int): Int { return 1 }
func run_it(g: func(Int): Int): String { return "one arg" }

var answer: String = run_it({ n => n + 1 })
print(answer)
print(answer.upper())
