# Emerald interpolates with `#{...}`. Interpolation written the way other
# languages write it stays in the String as written.
const name = "Ava"
print("Hello ${name}")
print("Hello {name}!")
const player = ["level": 3]
print("Score: #{player.count} of {name}")

func greet(person: String) {
    print("Hi {person}")
}

# Near misses: braces around something that is not a name in scope, JSON text,
# a raw string, an escaped interpolation, and real interpolation.
print("{count}")
print("{\"name\": \"Ava\"}")
print('{name}')
print("\#{name}")
print("#{name}")
print("{ name }")
print("{}")
