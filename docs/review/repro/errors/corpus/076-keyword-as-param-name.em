# Mistake: keyword used as a parameter name (line 5). Source: Altadmri & Brown 2015 (Blackbox), mistake H.
func move(from: Int, to: Int) {
    print(from, to)
}
func describe(when: String) {
    print(when)
}
describe("today")
