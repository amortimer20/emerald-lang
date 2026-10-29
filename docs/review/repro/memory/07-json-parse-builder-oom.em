# Json.parse: a failure while JsonBuilder.init builds its shared values
# crashes in its own errdefer cleanup (segfault at a near-null address).
print(Json.parse("{\"a\": [1, 2]}"))
