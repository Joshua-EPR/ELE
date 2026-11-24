// view and edit loans of Int, shape and Text locals; edits are visible to
// the owner after the loan ends.
shape Account {
    balance: Int
    owner: Text
}

flow deposit(a: edit Account, amount: Int) {
    a.balance = a.balance + amount
}

flow balanceOf(a: view Account) => Int {
    give a.balance
}

flow bump(n: edit Int) {
    n = n + 1
}

flow both(a: view Int, b: view Int) => Int {
    give a * 10 + b
}

flow ownerLength(a: view Account) => Int {
    give a.owner.byteLength
}

flow main() {
    change acc = Account(balance: 100, owner: "ana")
    deposit(edit acc, 50)
    deposit(edit acc, 25)
    print(balanceOf(view acc))
    print(ownerLength(view acc))
    change n = 5
    bump(edit n)
    bump(edit n)
    print(n)
    hold x = 4
    print(both(view x, view x))
    print(acc.balance + n)
}
