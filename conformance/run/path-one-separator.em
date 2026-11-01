# Section 15.3: paths Emerald produces use `/` on every platform, so a path from
# `Path.absolute` joins without mixing separators (Windows used to give `\` and `/`).
const file = "emerald-path-separator-conformance.txt"
File.write(file, "x")
const absolute = Path.absolute(file)
const joined = Path.join([absolute, "child"])
print(absolute.contains?("\\"), joined.contains?("\\"), joined.ends_with?("/child"))
print(Path.parent(joined) == absolute, Path.name(joined))
File.delete(file)
