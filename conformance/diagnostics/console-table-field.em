struct BadRow {
    const values: List[Int]
}
Console.table([BadRow([1, 2])])
