const answer=if true then 1+2 else if false then 3 else 4
print((if true then 1 else 2)+3)
print(2*(if false then 3 else 4))
print((if true then "abc" else "d").count)
const choose:func(Int):Int={n=>if n>0 then n else -n}
const nested=if (if true then false else true) then 1 else 2
