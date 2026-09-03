* 5
## The line above is a parse error on the very first token of a file, which used to crash
## the compiler with a .NET stack trace — Synchronise read the previous token without
## checking there was one. The explanation sits below the error on purpose: a comment
## emits a newline token, so anything above it would stop this being the first token and
## the test would no longer test what it is for.
##
## @export was the original trigger. It parses now that attributes are implemented, so
## this uses a token that cannot become valid.
var speed = 5.0
