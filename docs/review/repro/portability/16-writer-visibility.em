# 13.3/15.3: whether FileWriter text is visible to other reads before close is
# unstated. The interpreter writes through at once; a buffered backend would
# print "[]".
const path = "writer-visibility.txt"
const writer = File.create(path)
writer.write("live")
print("[" + File.read(path) + "]")
writer.close()
File.delete(path)
