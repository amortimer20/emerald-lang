# Section 14.1: a type declared in a file is one of its members, as are its
# type-level members. Calling a type-level function, naming an enum value, or
# constructing the type each initializes the file first, once.
print("call a type-level function")
print(Store.Plain.hello())
print("use an enum value")
print(Store.Mood.happy)
print("construct the class")
const p = Store.Plain()
print("done")
