// A constant cannot call a flow.
flow seven() => Int { give 7 }
fixed X = seven() + 1

flow main() {}
