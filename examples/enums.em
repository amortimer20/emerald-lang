# Enums and case

## An enum is a closed set of named values.
enum Weather {
    sunny
    rainy
    snowy

    ## A `case` that covers every value needs no `else`.
    const advice: String {
        return case self {
            when Weather.sunny then "Bring sunglasses."
            when Weather.rainy then "Bring an umbrella."
            when Weather.snowy then "Wear boots."
        }
    }
}

const forecast = [Weather.sunny, Weather.rainy, Weather.snowy, Weather.rainy]
var rainy_days = 0
for day in forecast {
    print("#{day}: #{day.advice}")
    case day {
        when Weather.rainy, Weather.snowy {
            rainy_days += 1
        }
        else { }
    }
}

## Without a subject, each `when` is a condition, tried from the top.
const summary = case {
    when rainy_days == 0 then "a dry week"
    when rainy_days < 3 then "a mixed week"
    else then "a wet week"
}
print("That makes #{summary}.")
