# Run: emerald run docs/review/repro/rules/25-closed-pipe-final-flush.em | true
# Output that is still buffered when the program ends meets a closed pipe: the CLI
# prints "error: WriteFailed" and a Zig stack trace from main.zig:482 and exits 1.
# A closed pipe met mid-run instead prints "emerald: could not write the program's
# output" and exits 70. Sections 13.2 and 18.1.
var total = 0
for i in 1..3000000 {
    total += i
}
print(total)
