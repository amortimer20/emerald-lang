# Section 15.10's `Program.environment` takes one variable name as a String and
# gives `String?`, which has to be unwrapped before it is used as text.
Program.environment(42)
Program.environment()
const read = Program.environment
const home: String = Program.environment("HOME")
