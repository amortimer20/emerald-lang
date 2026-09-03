# A test passes by returning true, or by not throwing. It fails by returning false, or
# by throwing.

@test
func leaves_a_value_inside_alone?(): Bool {
    return clamp(5, 0, 10) == 5
}

@test
func pulls_a_high_value_down?(): Bool {
    return clamp(15, 0, 10) == 10
}

@test
func pushes_a_low_value_up?(): Bool {
    return clamp(-5, 0, 10) == 0
}

@test
func handles_the_edges?(): Bool {
    return clamp(0, 0, 10) == 0 and clamp(10, 0, 10) == 10
}
