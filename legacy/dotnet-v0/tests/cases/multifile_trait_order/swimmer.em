trait Swimmer {
    abstract func stamina(): Int

    func swim(): String { return "swimming for #{self.stamina()} minutes" }
}
