enum Colour { RED }
enum Alignment { LEFT }

func describe(a: Alignment): String { return a.name }

print(describe(Colour.RED))
