struct Gauge {
    var level: Int

    var reading: Int {
        get {
            return self.level
        }
        set {
            self.level = value
            announce()
        }
    }
}

var gauge = Gauge(0)

func announce() {
    print(gauge)
}

gauge.reading = 5
