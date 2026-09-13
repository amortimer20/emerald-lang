using Scores

board.record(7)
board.record(3)
print(board.best(), Scores.board.best())

var local = Scores.Board([])
local.record(1)
print(local)
