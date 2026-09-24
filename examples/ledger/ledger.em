## The ledger's storage and reporting model. This file is part of the same
## project as main.em, so its public names are directly visible there.

class LedgerError extends Error { }

struct Entry with Textual, Hashable {
    const date: String
    const category: String
    const amount: Float
    const note: String

    @override
    func to_string(): String {
        return "#{self.date}  #{self.category.pad_end(14)}  #{self.amount.format(decimal_places: 2, group_digits: true)}  #{self.note}"
    }

    @override
    func equals(other: Entry): Bool {
        return self.date == other.date and self.category == other.category and self.amount == other.amount
    }

    @override
    func hash(): Int {
        return self.date.count * 31 + self.category.count * 17 + self.amount.format(decimal_places: 2).count
    }
}

const store_directory = ".emerald-ledger"
const store_path = Path.join([store_directory, "entries.tsv"])

func ensure_store() {
    Directory.create(store_directory)
}

func check_text(value: String, label: String) {
    if value.contains?("\t") or value.contains?("\n") or value.contains?("\r") {
        raise LedgerError("#{label} cannot contain a tab or line break")
    }
}

func valid_date(date: String): Bool {
    if date.count != 10 or date[4] != "-" or date[7] != "-" {
        return false
    }

    const year = date[0..<4].to_int_maybe()
    if year == nothing {
        return false
    }
    const month = date[5..<7].to_int_maybe()
    if month == nothing {
        return false
    }
    const day = date[8..<10].to_int_maybe()
    if day == nothing {
        return false
    }
    return year >= 1 and month.between?(1, 12) and day.between?(1, 31)
}

func parse_entry(line: String, number: Int): Entry {
    const fields = line.split("\t")
    if fields.count != 4 {
        raise LedgerError("entry #{number} in `#{store_path}` needs four tab-separated fields")
    }

    const amount = fields[2].to_float_maybe()
    if amount == nothing or not amount.finite?() {
        raise LedgerError("entry #{number} in `#{store_path}` has an invalid amount")
    }
    if not valid_date(fields[0]) {
        raise LedgerError("entry #{number} in `#{store_path}` has an invalid date")
    }
    if fields[1].empty?() {
        raise LedgerError("entry #{number} in `#{store_path}` has no category")
    }
    return Entry(fields[0], fields[1], amount, fields[3])
}

func load_entries(): List[Entry] {
    var entries: List[Entry] = []
    if not File.exists?(store_path) {
        return entries
    }
    File.with_open(store_path) { file =>
        var number = 1
        while true {
            const line = file.read_line()
            if line == nothing {
                break
            }
            entries.append(parse_entry(line, number))
            number += 1
        }
    }
    return entries
}

func import_entries(path: String): (Int, Int) {
    if not File.exists?(path) {
        raise LedgerError("`#{path}` does not exist")
    }
    var seen: Set[Entry] = load_entries().to_set()
    var imported = 0
    var total = 0
    File.with_open(path) { file =>
        var number = 1
        while true {
            const line = file.read_line()
            if line == nothing {
                break
            }
            const candidate = parse_entry(line, number)
            total += 1
            if not seen.contains?(candidate) {
                append_entry(candidate)
                seen.add(candidate)
                imported += 1
            }
            number += 1
        }
    }
    return (imported, total)
}

func append_entry(entry: Entry) {
    ensure_store()
    const line = "#{entry.date}\t#{entry.category}\t#{entry.amount}\t#{entry.note}\n"
    if File.exists?(store_path) {
        File.append(store_path, line)
    }
    else {
        File.write(store_path, line)
    }
}

func entries_in(period: String): List[Entry] {
    if period == "" {
        return load_entries()
    }
    return load_entries().filter { entry => entry.date.starts_with?(period) }
}

func joined_note(arguments: List[String], start: Int): String {
    var note = ""
    for index in start..<arguments.count {
        if index > start {
            note += " "
        }
        note += arguments[index]
    }
    return note
}
