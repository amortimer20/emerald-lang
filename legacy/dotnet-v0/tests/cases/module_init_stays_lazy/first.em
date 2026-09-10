## Nothing in the entry file names First. It is reached only from second.em, while that
## file's own initializer is running, so this line belongs after both of the lines below.
print("first initializing")

var value = 1
