# Mistake: comparing an optional with > (line 3). Source: review brief list (method on an optional).
var n = "5".to_int_maybe()
if n > 3 {
    print("big")
}
