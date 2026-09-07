## Nothing in the entry file touches First directly. It is reached only from second.em,
## and only while that file's own initializer runs -- so this line should appear after
## "entry" and after "second initializing", not before either.
print("first initializing")

var value = 1
