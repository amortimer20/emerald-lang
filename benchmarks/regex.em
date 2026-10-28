# Regular expressions: finding dates in many lines of text.

const pattern = Regex("(\\d{4})-(\\d{2})-(\\d{2})")
var lines: List[String] = []
for index in 0..<30000 {
    lines.append("entry #{index} on 2026-#{(index % 12 + 1).to_string().pad_start(2, "0")}-15 and more text")
}
var months = 0
for line in lines {
    const found = pattern.find(line)
    if found != nothing {
        months += 1
    }
}
print(months)
