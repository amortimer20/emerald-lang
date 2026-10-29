# Section 15.2: `input` removes the line ending but keeps other whitespace, and Enter
# alone returns "".
const first = input()
print("[#{first}]", first.count)
const empty = input()
print("[#{empty}]", empty.empty?())
print(input())
