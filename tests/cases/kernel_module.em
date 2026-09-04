## §3.3: the kernel is callable bare or qualified, so the one namespace nobody could
## explore becomes explorable by typing Kernel and a dot. Same functions either way —
## Kernel is the dictionary the bare names come from, not a copy of it.
Kernel.print("qualified")
print("bare")
print(Kernel.random(1) >= 0)
