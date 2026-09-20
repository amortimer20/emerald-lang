# Path

`Path` performs lexical path manipulation without opening a file or directory. Run
[`conformance/run/path.em`](../../conformance/run/path.em) for every operation below.

## join(parts: List[String]) -> String

Combines zero or more path parts with `/`, the same on every platform Emerald runs on.

## name, stem, extension, parent

`name(path: String) -> String` returns the final component; `stem` removes its final
extension; `extension` returns that extension without its dot (or `""`); and `parent`
returns the containing path (or `""`).

## absolute?(path: String) -> Bool

Whether `path` is written as an absolute path on this platform. It does not test whether the
path exists. Resolving an existing path with `Path.absolute` is part of the filesystem chunk.
