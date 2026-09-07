## KNOWN HOLE. The output below is wrong and is recorded so that fixing it shows up as a
## changed golden rather than as a silent improvement.
##
## Definite assignment covers reading a field directly. It does not cover *calling a
## method* before the fields are assigned, and a method can read whatever it likes. So a
## non-nullable String is observably nothing here, in the one language feature that is
## supposed to make that impossible, and nothing is reported until the program runs.
##
## The fix is local, not interprocedural: before every required field is definitely
## assigned, reject instance-method calls; after, allow them. The checker never has to
## look inside shout to enforce that.

class Greeter {
    var name: String

    func shout(): String { return self.name.upper() }

    constructor() {
        print(self.shout())
        self.name = "ada"
    }
}

Greeter()
