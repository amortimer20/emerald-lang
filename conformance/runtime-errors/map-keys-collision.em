# D6: map_keys with a colliding key is an error naming the two keys.

var scores = ["ann": 1, "bob": 2, "cy": 3]
print(scores.map_keys { name => name.count })
