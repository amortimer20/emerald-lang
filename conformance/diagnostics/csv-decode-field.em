struct Bad {
    const tags: List[String]
}

const values =
    Csv.decode("tags\na", as: List[Bad])
