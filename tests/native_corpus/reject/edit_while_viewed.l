// An edit loan cannot coexist with a view loan of the same value.
flow both(a: view Int, b: edit Int) => Int {
    give a
}

flow main() => Int {
    change n = 1
    give both(view n, edit n)
}
