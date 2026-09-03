import io
p = 'src/Emerald/Scanner.cs'
s = io.open(p, encoding='utf-8').read()

old = """        if (Peek() == '[')            // #[ ... ]# block, nesting
        {
            Advance();
            int depth = 1;
            while (!AtEnd && depth > 0)
            {
                if (Peek() == '#' && PeekNext() == '[') { Advance(); Advance(); depth++; }
                else if (Peek() == ']' && PeekNext() == '#') { Advance(); Advance(); depth--; }
                else { if (Peek() == '\n') _line++; Advance(); }
            }
            if (depth > 0) Error("This block comment is never closed.");
        }"""

new = """        if (Peek() == '[')            // #[ ... ]# block, nesting
        {
            int opened = _line;
            Advance();
            int depth = 1;
            while (!AtEnd && depth > 0)
            {
                if (Peek() == '#' && PeekNext() == '[') { Advance(); Advance(); depth++; }
                else if (Peek() == ']' && PeekNext() == '#') { Advance(); Advance(); depth--; }
                else { if (Peek() == '\n') _line++; Advance(); }
            }
            if (depth > 0) Error("This block comment is never closed.");
            else if (_line > opened) BlockComments.Add((opened, _line));
        }"""

assert old in s
s = s.replace(old, new, 1)

old2 = "    public List<Diagnostic> Diagnostics { get; } = [];"
new2 = """    public List<Diagnostic> Diagnostics { get; } = [];

    /// <summary>
    /// First and last line of each multi-line <c>#[ ]#</c> comment. The formatter needs
    /// these: what is inside a block comment is freeform text — a diagram, a pasted
    /// sample — and re-indenting it would destroy the only thing its layout was for.
    /// Recorded here rather than re-derived, since finding them again means repeating the
    /// nesting and string rules this scanner already has.
    /// </summary>
    public List<(int From, int To)> BlockComments { get; } = [];"""

assert old2 in s
s = s.replace(old2, new2, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("ok")
