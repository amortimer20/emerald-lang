# Typed CSV decoding binds columns by field name, converts scalar cells, and
# lets defaults and optionals keep their ordinary Emerald behavior.
enum Team { red, blue }

struct Score {
    const name: String
    const points: Int
    const ratio: Float
    const active: Bool
    const team: Team
    const note: String = "default note"
    const comment: String?
}

const scores = Csv.decode("name,points,ratio,active,team,note,comment\nAda,120,2.0,TRUE,red,,\nGrace,95,1.5,false,blue,kept,hello", separator: ",", as: List[Score])
print(scores.count)
print("#{scores[0].name}: #{scores[0].points} #{scores[0].ratio} #{scores[0].active} #{scores[0].team} #{scores[0].note} #{scores[0].comment}")
print("#{scores[1].name}: #{scores[1].points} #{scores[1].ratio} #{scores[1].active} #{scores[1].team} #{scores[1].note} #{scores[1].comment}")

struct Compact {
    const name: String
    const points: Int
}
const compact = Csv.decode("name,points,unused\nAda,120,ignored", as: List[Compact])
print("#{compact[0].name}: #{compact[0].points}")

struct Defaults {
    const name: String
    const note: String = "default"
    const comment: String?
}
const defaults = Csv.decode("name\nAda", as: List[Defaults])
print("#{defaults[0].name}: #{defaults[0].note} #{defaults[0].comment}")

struct Dated {
    const date: Date
}
const dated = Csv.decode("date\n2026-09-28", as: List[Dated])
print(dated[0].date)
