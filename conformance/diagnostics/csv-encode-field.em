struct Bad {
    const tags: List[String]
}

const values = [Bad(["welcome"])]
Csv.encode(values)
