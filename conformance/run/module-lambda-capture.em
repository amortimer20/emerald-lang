# Section 7.4: creating a module lambda does not read its captures. Its call
# happens after `ready` receives a value, so the capture is safe.
const report: func(): Int = { => ready }
var ready = 7
print(report())
