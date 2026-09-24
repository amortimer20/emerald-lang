# A type declared as a block's last statement must not take the block's
# own closing brace with it during recovery.
func make() {
    struct Local {}
}

func many() {
    class First {}
    enum Second { only }
}

if true {
    trait Third {}
}
