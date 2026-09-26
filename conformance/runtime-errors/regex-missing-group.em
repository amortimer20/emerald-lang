# Asking a match for a group its pattern does not have raises RegexError at
# the program's own call, naming the groups the pattern does have.
const found = Regex('(\d+)-(\d+)').find_all("10-20")[0]
print(found.group(1))
print(found.group(3))
