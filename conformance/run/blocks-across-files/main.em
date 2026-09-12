using Tools

const scale = 10

print(apply([1, 2, 3]) { value => value * scale })
print(apply([1, 2]) { value => Tools.triple(value) })
