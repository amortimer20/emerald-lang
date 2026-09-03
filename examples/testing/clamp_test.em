# assert reports the expression, not just that something was false.
#
# A function receiving `false` can say nothing more than "it failed". assert reads the
# expression itself, so it can show what was compared and what each side actually was.

@test
func leaves_a_value_inside_alone() {
    assert clamp(5, 0, 10) == 5
}

@test
func pulls_a_high_value_down() {
    assert clamp(15, 0, 10) == 10
}

@test
func pushes_a_low_value_up() {
    assert clamp(-5, 0, 10) == 0
}

@test
func handles_the_edges() {
    assert clamp(0, 0, 10) == 0
    assert clamp(10, 0, 10) == 10
}

# A failing one would report:
#
#   FAIL  ClampTest.pulls_a_high_value_down
#         Assertion failed:  clamp(15, 0, 10) == 10
#         left  was 15
#         right was 10
