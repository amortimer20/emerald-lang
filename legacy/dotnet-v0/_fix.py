# -*- coding: utf-8 -*-
import io
p = "src/Emerald/Scanner.cs"
s = io.open(p, encoding="utf-8").read()
old = """    private char Peek() => AtEnd ? '\0' : source[_current];
    private char PeekNext() => _current + 1 >= source.Length ? '\0' : source[_current + 1];"""
new = """    private char Peek() => AtEnd ? '\0' : source[_current];
    private char PeekNext() => _current + 1 >= source.Length ? '\0' : source[_current + 1];

    /// <summary>Look <paramref name="ahead"/> characters on, for the exponent guard.</summary>
    private char Peek(int ahead) =>
        _current + ahead >= source.Length ? '\0' : source[_current + ahead];"""
assert old in s, "peek anchor"
s = s.replace(old, new, 1)
if "using System.Globalization;" not in s:
    s = "using System.Globalization;\n" + s
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("ok")
