# Section 14.1's `Program.arguments`: the list of only the program's own
# arguments. The conformance runner passes none, so it is always empty here;
# `emerald.zig`'s own tests cover what a program actually receives.
print(Program.arguments, Program.arguments.count, Program.arguments.empty?())
