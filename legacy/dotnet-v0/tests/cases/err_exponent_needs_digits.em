## An 'e' only begins an exponent when digits follow it — the same guard the decimal
## point has, which is what keeps 1..5 lexing as a range rather than as 1. and .5.
##
## Before this the guard declined correctly and then said nothing: 1e lexed as the
## number 1 beside the name e, so the reader was told there is no variable named e and
## offered Math.e, which mentions nothing they were trying to write.
var x = 1e
