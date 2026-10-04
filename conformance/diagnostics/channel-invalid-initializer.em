const optional: Channel[Int?] = Channel()
const optional_list: Channel[List[Int]?] = Channel(capacity: 1)
const unknown: Channel[Missing] = Channel()
