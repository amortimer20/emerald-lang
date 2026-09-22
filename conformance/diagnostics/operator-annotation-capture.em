struct Amount {
    const value: Int

    @operator("*")
    func times(count: Int): Amount {
        return Amount(later)
    }
}

const product = Amount(1) * 2
const later = 10
