# No imports — every .em file beside this one is part of the project.

var pets = [Dog("Rex"), Cat("Momo")]

for i in 0..1 {
    print(pets[i].introduce())
}

print(SoundUtils.loudly("quiet down"))
print(SoundUtils.repeat("na ", 4) + "batman")
