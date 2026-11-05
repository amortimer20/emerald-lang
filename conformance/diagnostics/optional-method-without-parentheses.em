struct Box {
    const value: Int

    func doubled(): Int {
        return self.value * 2
    }
}

const box: Box? = Box(2)
print(box?.doubled)
