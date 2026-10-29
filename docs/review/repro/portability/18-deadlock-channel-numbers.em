# 15.13: deadlock diagnostics "name task results or channel directions and
# their original source locations". The interpreter also numbers channels by
# creation ("channel 2"), and conformance/runtime-errors/channel-*-deadlock
# encode "channel 1".
const first: Channel[Int] = Channel()
const second: Channel[Int] = Channel()
second.send(1)
