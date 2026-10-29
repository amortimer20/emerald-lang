# Probe: arguments and environment.
for a in Program.arguments {
    print(a, a.count, a.code_points())
}
print(Program.environment("EM_PROBE"), Program.environment("EM_PROBE").or("").count, Program.environment("em_probe"))
print(Program.environment("EM_EMPTY"), Program.environment(""), Program.environment("A=B"))
exit(Program.arguments.count)
