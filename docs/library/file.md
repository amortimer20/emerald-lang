# File, Directory, and Path

`File`, `Directory`, and `Path` are the standard library's text-file, directory, and path
namespaces. Run [`conformance/run/file-directory-path.em`](../../conformance/run/file-directory-path.em)
for whole-file and path work, [`conformance/run/file-streaming.em`](../../conformance/run/file-streaming.em)
for streamed reads, and [`conformance/runtime-errors/file-streaming-closed.em`](../../conformance/runtime-errors/file-streaming-closed.em)
for a typed failure.

## File

`read(path: String) -> String`, `write(path: String, contents: String) -> Nothing`, and
`append(path: String, contents: String) -> Nothing` read or replace/extend UTF-8 text.
`read_lines(path: String) -> List[String]` splits lines, and
`write_lines(path: String, lines: List[String]) -> Nothing` writes every line with a trailing
newline, including the last. `exists?(path: String) -> Bool` tests for a file.

`copy(source: String, destination: String) -> Nothing`,
`move(source: String, destination: String) -> Nothing`, and `delete(path: String) -> Nothing`
perform their named whole-file operation.

`open(path: String) -> FileHandle` opens read-only UTF-8 text. `with_open(path: String,
block: func(FileHandle)) -> Nothing` gives its block an open handle and closes it after normal
completion, return, or an error.

### FileHandle

`read() -> String` returns all text remaining after the current position. `read_line() ->
String?` returns the next line without its newline, or `nothing` at end of file. Like
`read_lines`, it does not add an empty final line for a trailing newline, but does return an
unterminated final line. `close() -> Nothing` is idempotent. Handles are read-only; use
`File.write` or `File.append` for whole-file writes.

## Directory

`exists?(path: String) -> Bool` tests for a directory. `create(path: String) -> Nothing`
creates all missing parents and is idempotent. `delete(path: String) -> Nothing` removes only
an empty directory; `delete_recursive(path: String) -> Nothing` removes a directory and
everything inside it, and is idempotent — deleting an already-gone path is not an error, the
same as `create`. `list(path: String) -> List[String]` returns full paths for its direct files
and subdirectories; their order is unspecified.

## Path

`join(parts: List[String]) -> String`, `name(path: String) -> String`, `stem(path: String) -> String`,
`extension(path: String) -> String`, and `parent(path: String) -> String` are lexical only.
`extension` has no leading dot and `parent` uses `""` where none exists.
`absolute?(path: String) -> Bool` tests syntax; `absolute(path: String) -> String` resolves an
existing path to an absolute path.

## Raises

Every non-predicate operation raises `FileError` for a missing path, denied access, invalid
UTF-8 text, or a failed write. `FileHandle.read` and `read_line` also raise it when called
after `close`. `Directory.create` and `Directory.delete_recursive` are idempotent when a
missing path is the point; `Directory.delete` reports a non-empty directory rather than
deleting its contents. `FileError` extends `RuntimeError`, so a program can catch filesystem
failures without catching unrelated runtime failures.
