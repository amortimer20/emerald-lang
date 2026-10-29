# Out of area (not a platform difference): aborts with exit 134 on macOS,
# Linux aarch64 and Linux x86-64 alike. Four items in one group run; five abort.
print("a b c d e".split(" ").group_by { w => w.count })
