# Section 15.4's groups: numbered from 1 by their opening parentheses, with
# group 0 the whole match, and named with (?<name>...).
const us_date = Regex('(?<month>\d{1,2})/(?<day>\d{1,2})/(?<year>\d{4})')
const due = us_date.find("Due 9/25/2026")
if due != nothing {
    print(due.group(0), due.group(1), due.group(2), due.group(3))
    print(due.named("year"), due.named("month"), due.named("day"))
    print(Date(due.named("year").to_int(), due.named("month").to_int(), due.named("day").to_int()))
}

# Nested groups count by where they open.
const nested = Regex('((\w+)@(\w+))\.com').find("mail ana@example.com")
if nested != nothing {
    print(nested.group(1), nested.group(2), nested.group(3), nested.group_maybe(3))
}

# A group that took no part, as an optional group without its text or the
# branch not taken: the _maybe forms give nothing, the others raise.
const phone = Regex('(\d{3})-(\d{4})(?: ext\. (?<extension>\d+))?')
for text in ["555-1234 ext. 89", "555-1234"] {
    const found = phone.find(text)
    if found != nothing {
        print(found.group(1), found.group_maybe(3), found.named_maybe("extension"))
    }
}
const either = Regex('(cat)|(dog)').find("hotdog")
if either != nothing {
    print(either.group_maybe(1), either.group_maybe(2), either.group(2))
}

# A repeated group holds its last time round.
const last = Regex('(\w)+').find("abc")
if last != nothing {
    print(last.group(0), last.group(1))
}

# Groups inside a computed replacement.
print(Regex('(?<first>\w+) (?<last>\w+)').replace_each("Ada Lovelace, Alan Turing") { found => "#{found.named("last")} #{found.named("first")}" })
print(Regex('(\d+)x(\d+)').replace_each("3x4 and 10x2") { found => (found.group(1).to_int() * found.group(2).to_int()).to_string() })

# Asking for a group that took no part, or one the pattern does not have.
func attempt(label: String, block: func(): String?) {
    try {
        print(label, block())
    }
    catch error: RegexError {
        print(label, error.message)
    }
}

const word = Regex('(a)|(b)').find_all("b")[0]
attempt("unset") { => word.group(1) }
attempt("unset maybe") { => word.group_maybe(1) }
attempt("too high") { => word.group(3) }
attempt("too high maybe") { => word.group_maybe(3) }
attempt("negative") { => word.group(-1) }
attempt("no groups") { => Regex('x').find_all("x")[0].group(1) }
attempt("no names") { => word.named("a") }
attempt("unknown name") { => due?.named("years") }
attempt("unknown maybe") { => due?.named_maybe("") }
attempt("one name") { => Regex('(?<only>x)').find_all("x")[0].named("other") }
attempt("two names") { => Regex('(?<one>x)(?<two>y)').find_all("xy")[0].named("three") }
const optional_name = Regex('(?<sign>-)?\d+').find_all("42")[0]
attempt("unset name") { => optional_name.named("sign") }
attempt("unset name maybe") { => optional_name.named_maybe("sign") }
