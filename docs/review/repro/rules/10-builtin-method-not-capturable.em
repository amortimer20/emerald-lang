# Section 7.4: a bare capture of a higher-order method whose output type depends on a
# block needs an expected callable type; one with it is accepted.
const numbers = [1, 2, 3]
const mapper = numbers.map
const typed: func(func(Int): String): List[String] = numbers.map
const counter = numbers.count
