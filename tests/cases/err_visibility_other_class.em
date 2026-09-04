## A different class is outside, even when it is holding one.
class Account {
    var _balance: Int = 0
}

class Thief {
    func peek(account: Account): Int { return account._balance }
}
