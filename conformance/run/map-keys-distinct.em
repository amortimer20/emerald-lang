# map_keys keeps every entry when the produced keys differ.

print(["a": 1, "bb": 2].map_keys { key => key.count })
