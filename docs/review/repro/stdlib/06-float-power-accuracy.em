# Finding 06: Float ** and Math.power lose about 12 significant digits' worth of accuracy for
# large exponents. Expected (correctly rounded pow, as C's and Python's give):
#   2.4699329180060256e+41  and  2.600334596395491e+267
print(1.1 ** 1000.0)
print(Math.power(1.005, 123456.789))
