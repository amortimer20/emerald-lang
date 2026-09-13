# Classes

## A class looks like a struct, but its values are objects that are shared
## rather than copied. Every name holding one refers to the same object.
class Playlist {
    var name: String
    var songs: [String] = []

    func add(song: String) {
        self.songs.append(song)
    }

    const length: Int {
        return self.songs.count
    }
}

## `const` fixes which object `mix` refers to. The object itself can still
## change, and everything sharing it sees the change.
const mix = Playlist("Road trip")
const same = mix
same.add("Drive")
mix.add("Home")
print(mix.name, mix.length, same.songs)

## Passing an object to a function shares it too, so the function can change it.
func rename(playlist: Playlist, to: String) {
    playlist.name = to
}
rename(mix, "Summer")
print(same.name)

## Two objects are equal only when they are the same object, even if every field
## matches.
print(mix == same, Playlist("Summer") == Playlist("Summer"))

## A block written in a method can use `self`, because the object is shared.
class Counter {
    var count: Int = 0

    func incrementer(): func() {
        return { => self.count += 1 }
    }
}

const counter = Counter()
const tick = counter.incrementer()
tick()
tick()
print(counter)
