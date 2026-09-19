# Section 9.3's broader numerical namespace. Angles are radians; every
# operation produces Float and accepts Int arguments through ordinary widening.

print(Math.pi, Math.e)
print(Math.sin(0), Math.cos(0), Math.tan(0))
print(Math.arc_sin(0), Math.arc_cos(1), Math.arc_tan(0), Math.arc_tan2(1, 0))
print(Math.natural_log(Math.e), Math.log10(100), Math.log(8, 2), Math.power(2, 3))
print(Math.arc_sin(2).nan?(), Math.natural_log(-1).nan?(), Math.log(10, 1).nan?(), Math.power(-1, 0.5).nan?())
print(Math.pi.type_name, Math.power(2, 3).type_name)
