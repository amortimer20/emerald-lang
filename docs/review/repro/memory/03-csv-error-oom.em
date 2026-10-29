# A CsvError whose struct allocation fails: Heap.createStruct releases and
# frees `fields`, then makeCsvError's errdefer releases and frees them again.
try {
    print(Csv.parse("a,b\n1", separator: ";;"))
}
catch error {
    print(error.message)
}
