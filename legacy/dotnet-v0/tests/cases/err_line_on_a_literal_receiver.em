## A failure inside a call belongs to the line the call is on. Only a member *read* set
## that line, so a receiver that was a variable set it on the way past and a literal one
## did not — this reported main.em:0 wherever it sat.


print("banana".to_int())
