## Every part of this is a literal, and a literal carried no token — so the diagnostic
## came out at line 0 with no source line to quote, which is the one thing every message
## is supposed to have.
var x = if true then "a" else 42
