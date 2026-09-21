const file = File.open("conformance/runtime-errors/file-missing.em")
file.close()
file.close()
file.read_line()
