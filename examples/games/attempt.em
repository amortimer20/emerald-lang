# One guess and how it scored. A struct because it is a value: once a guess is made,
# neither the word nor its marks ever change again.
#
# The pair used to be two lists side by side in Wordle, indexed together. Keeping them
# in step was the caller's job, and walking them meant `0..(count - 1)` — which counts
# backwards when there are no guesses yet.

struct Attempt {
    var word: String
    var marks: List<Mark>
}
