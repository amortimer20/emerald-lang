# 14.1: a module file "initializes once when one of its members is first
# accessed". A type-level function and an enum value do not initialize the
# file; constructing a type does.
print("call a type-level function")
print(Store.Plain.hello())
print("use an enum value")
print(Store.Mood.happy)
print("construct the class")
const p = Store.Plain()
print("done")
