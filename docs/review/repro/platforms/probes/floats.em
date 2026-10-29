# Probe: float display at extremes, format, round_to.
print(5e-324, -5e-324, 2.2250738585072014e-308, 2.225073858507201e-308)
print(1e308, 1.7976931348623157e308, -1.7976931348623157e308, 1e308 * 10)
print(-0.0, 0.0 * -1, Float.nan, -Float.nan, Float.infinity, -Float.infinity, Float.infinity - Float.infinity)
print(0.1 + 0.2, 1.0 / 3, 2.0 / 3, 1e16, 9007199254740993.0, 123456789012345680000.0)
print(1e-6, 9.999999999999999e-7, 1e-7, 1.5e-310)
print(5e-324.format(decimal_places: 100))
print(1e308.format(decimal_places: 2))
print((-0.0).format(decimal_places: 2), (-0.001).format(decimal_places: 2), (-0.0).format())
print(0.125.format(decimal_places: 2), 0.375.format(decimal_places: 2), 2.675.format(decimal_places: 2), 1.005.format(decimal_places: 2))
print(1e22.format(decimal_places: 0, group_digits: true), 123456789.987654321.format(decimal_places: 9))
print(2.675.round_to(2), 1.005.round_to(2), 0.285.round_to(2), 1.0e-320.round_to(320), 123456.789.round_to(-3))
print((-0.4).round_to(0), (-0.0).round_to(5), 5e-324.round_to(323), 1e308.round_to(-308), 1.7976931348623157e308.round_to(-308))
for k in 0..40 {
    const x = 1.0 / (k + 3) * 10.0 ** (k - 20)
    print(x, x.round_to(k - 10), x.format(decimal_places: k))
}
