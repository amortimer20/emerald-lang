# Mistake: break inside an each block (line 4). Source: guide docs/language/core.md.
var nums = [1, 2, 3]
nums.each { n =>
    break if n > 1
    print(n)
}
