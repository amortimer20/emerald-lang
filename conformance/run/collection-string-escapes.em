# A string inside a collection reads back as the same text (15.2).

print(["\#{x}", "5", "#", "a#b"])
print(["bell\u{7}", "esc\u{1B}[31m", "del\u{7F}", "c1\u{85}", "tab\t", "nul\0"])
print(["quote\" back\\"])
