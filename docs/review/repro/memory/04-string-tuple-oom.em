# String.partition's three-part tuple whose tuple allocation fails:
# createTuple frees `items`, then stringTuple's errdefer releases them.
print("key=value".partition("="))
