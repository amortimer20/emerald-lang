print([1, 2, 3, 4].partition { number => number.even?() })
print(["Ada", "Grace", "Ada", "Linus"].group_by { name => name[0] })
print([1, 2, 2, 3].frequencies())
