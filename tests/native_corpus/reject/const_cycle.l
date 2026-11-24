// Constants cannot depend on each other cyclically.
fixed A = B + 1
fixed B = A * 2

flow main() {}
