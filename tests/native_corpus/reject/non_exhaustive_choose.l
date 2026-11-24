// Every variant of a choice must be handled by choose.
choice Light {
    Red,
    Green,
    Yellow,
}

flow code(l: Light) => Int {
    choose l {
        Light.Red: { give 1 },
        Light.Green: { give 2 },
    }
    give 0
}

flow main() => Int {
    give code(Light.Yellow)
}
