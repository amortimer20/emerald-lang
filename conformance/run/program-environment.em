# Section 15.10's `Program.environment` reads one environment variable and gives
# `nothing` when it is not set. The conformance runner gives programs no
# environment at all, so every variable is unset here; `emerald.zig`'s own tests
# cover a variable that is set, and one that is not UTF-8 text. No variable is
# named "" or has `=` in its name, so asking for one finds nothing too.
const key = Program.environment("WEATHER_KEY").or("")
print(key.blank?())
print(Program.environment("HOME"), Program.environment(""), Program.environment("A=B"))
if Program.environment("PATH") == nothing {
    print("no PATH")
}
