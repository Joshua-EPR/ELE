// Static Text values: binding, passing, returning, Unicode; scopes/shadowing.
fn saludo(n: Int) -> Text {
    if n > 0 { return "hola ñandú 👋" }
    return "adiós"
}
fn eco(t: Text) -> Text = t
fn main() {
    let t = saludo(1)
    print(eco(t))
    print(saludo(0))
    print("llaves {{literales}} y \"comillas\"\tcon tab")
    let x = 1
    {
        let x = 2
        print(x)
    }
    print(x)
    var s = "a"
    s = "b"
    print(s)
}
