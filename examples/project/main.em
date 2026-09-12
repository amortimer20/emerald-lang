## A program in more than one file.
##
## A directory becomes a project when it holds `main.em`. Every `.em` file
## under it is part of the program — there is nothing to import and no list to
## keep up to date. Only this file runs its top level; the rest hold
## declarations.
##
## Run it with `emerald run examples/project/main.em`.

using Scoring

const rolls = [10, 7, 3, 9, 0, 6]

print("rolls    ", rolls)
print("total    ", total(rolls))
print("best     ", best(rolls))
print("average  ", average(rolls))
print("grade    ", Scoring.grade(average(rolls)))
print("pass mark", Scoring.pass_mark)
