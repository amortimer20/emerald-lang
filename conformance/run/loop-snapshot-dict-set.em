# Section 8.4: a `for` loop iterates the snapshot taken when it begins, so later
# mutation of a dictionary or set never changes the visited sequence.
var ages: Dict[String, Int] = ["Ava": 12, "Bo": 13]
for (name, age) in ages {
    print(name, age)
    ages["Cy"] = 14
    ages.remove("Bo")
}
print(ages)
var colors: Set[String] = ["red", "green"]
for color in colors {
    print(color)
    colors.add("blue")
    colors.remove("green")
}
print(colors)
