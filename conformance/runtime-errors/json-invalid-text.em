# Text that is not JSON raises JsonError with the line and column of the
# first mistake.
const settings = Json.parse("""
{
  "volume": 7,
  "theme": "dark",
}
""")
print(settings)
