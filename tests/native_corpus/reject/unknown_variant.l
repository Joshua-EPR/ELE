// A variant that the choice does not declare.
choice Light {
    Red,
    Green,
}

flow main() => Int {
    hold l = Light.Blue
    give 0
}
