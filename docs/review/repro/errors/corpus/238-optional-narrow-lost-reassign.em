# Mistake: narrowing undone by reassignment (line 5). Source: guide docs/language/types-and-optionals.md.
var n = "5".to_int_maybe()
if n != nothing {
    n = "x".to_int_maybe()
    print(n + 1)
}
