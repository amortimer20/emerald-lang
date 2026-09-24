# Every file already sees the built-ins, so `using Emerald` is reported as
# redundant, as a warning.
using Emerald

print(File.exists?("x"))
