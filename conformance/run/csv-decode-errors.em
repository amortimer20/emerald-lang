# Typed conversion errors retain the CSV line and the struct field name.
func show(block: func()) {
    try {
        block()
    }
    catch error: CsvError {
        print(error.message)
        print(error.line.or(-1))
    }
}

struct Score {
    const name: String
    const points: Int
    const active: Bool
}

show { =>
    Csv.decode("name,points,active\nAda,twelve,true", as: List[Score])
}
show { =>
    Csv.decode("name,points,active\nAda,,true", as: List[Score])
}
show { =>
    Csv.decode("name,points,active\nAda,12,many", as: List[Score])
}
show { =>
    Csv.decode("name,points\nAda,12", as: List[Score])
}
show { =>
    Csv.decode("name,points,active\nAda,12,true\nGrace,13,false,extra", as: List[Score])
}
