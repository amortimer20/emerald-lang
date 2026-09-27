struct Save {
    const name: String
    const seen: Set[String]
}

Json.encode(Save("Ada", ["welcome"].to_set()))
