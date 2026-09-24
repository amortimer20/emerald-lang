## A small persisted personal-finance ledger.
##
## Run from this directory's parent, for example:
##   emerald run examples/ledger/main.em -- add 2026-09-20 groceries -42.75 "market"
##   emerald run examples/ledger/main.em -- summary 2026-09

func usage() {
    print("Ledger — a tab-delimited personal-finance journal")
    print("  add DATE CATEGORY AMOUNT [NOTE...]")
    print("  list [YYYY-MM]")
    print("  summary [YYYY-MM]")
    print("  category NAME")
    print("  import FILE")
}

func add(arguments: List[String]) {
    if arguments.count < 4 {
        usage()
        exit(64)
    }

    const date = arguments[1]
    const category = arguments[2].trim()
    const amount = arguments[3].to_float_maybe()
    const note = joined_note(arguments, 4)

    if not valid_date(date) {
        raise LedgerError("`#{date}` is not a YYYY-MM-DD date")
    }
    if category.empty?() {
        raise LedgerError("a ledger entry needs a category")
    }
    if amount == nothing or not amount.finite?() {
        raise LedgerError("`#{arguments[3]}` is not a finite amount")
    }
    check_text(category, "a category")
    check_text(note, "a note")

    const entry = Entry(date, category, amount, note)
    append_entry(entry)
    print("Added #{entry}.")
}

func list(period: String) {
    const entries = entries_in(period).sort_by { entry => entry.date }
    if entries.empty?() {
        print("No entries.")
        return
    }
    entries.each { entry => print(entry) }
}

func summary(period: String) {
    const entries = entries_in(period)
    if entries.empty?() {
        print("No entries.")
        return
    }

    var total: Float = 0
    var income: Float = 0
    var spending: Float = 0
    var categories: Dict[String, Float] = []

    entries.each { entry =>
        total += entry.amount
        categories[entry.category] = categories[entry.category].or(0) + entry.amount
        if entry.amount >= 0 {
            income += entry.amount
        }
        else {
            spending += entry.amount
        }
    }

    print("Entries: #{entries.count}")
    print("Income:   #{income.format(decimal_places: 2, group_digits: true)}")
    print("Spending: #{spending.format(decimal_places: 2, group_digits: true)}")
    print("Net:      #{total.format(decimal_places: 2, group_digits: true)}")
    print("By category:")
    categories.keys().sort().each { category =>
        print("  #{category.pad_end(14)} #{categories[category].or(0).format(decimal_places: 2, group_digits: true)}")
    }
}

func show_category(name: String) {
    const entries = entries_in("").filter { entry => entry.category == name }.sort_by { entry => entry.date }
    if entries.empty?() {
        print("No entries in `#{name}`.")
        return
    }
    entries.each { entry => print(entry) }
    print("Total: #{entries.map { entry => entry.amount }.sum().format(decimal_places: 2, group_digits: true)}")
}

const arguments = Program.arguments
if arguments.empty?() {
    usage()
    return
}

case arguments[0] {
    when "add" {
        add(arguments)
    }
    when "list" {
        if arguments.count > 2 {
            usage()
            exit(64)
        }
        list(arguments.drop(1).first.or(""))
    }
    when "summary" {
        if arguments.count > 2 {
            usage()
            exit(64)
        }
        summary(arguments.drop(1).first.or(""))
    }
    when "category" {
        if arguments.count != 2 {
            usage()
            exit(64)
        }
        show_category(arguments[1])
    }
    when "import" {
        if arguments.count != 2 {
            usage()
            exit(64)
        }
        const (imported, total) = import_entries(arguments[1])
        print("Imported #{imported} of #{total} entries (#{total - imported} skipped as duplicates).")
    }
    else {
        usage()
        exit(64)
    }
}
