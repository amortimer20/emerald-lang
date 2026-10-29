# Mistake: reading a private field from outside (line 6). Source: carry-over from Java/C (private access).
class Account {
    var _balance: Int = 0
}
var a = Account()
print(a._balance)
