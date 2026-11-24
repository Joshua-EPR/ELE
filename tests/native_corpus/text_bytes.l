// byteLength and byteAt over literal, built and borrowed Text, including
// multibyte UTF-8.
flow count(t: view Text, b: Int) => Int {
    change total = 0
    each i among 0..t.byteLength {
        when t@byteAt(i) == b { total += 1 }
    }
    give total
}

flow codepoints(t: view Text) => Int {
    change total = 0
    each i among 0..t.byteLength {
        hold b = t@byteAt(i)
        when b < 128 || b >= 192 { total += 1 }
    }
    give total
}

flow same(a: view Text, b: view Text) => Bool {
    when a.byteLength != b.byteLength { give false }
    each i among 0..a.byteLength {
        when a@byteAt(i) != b@byteAt(i) { give false }
    }
    give true
}

flow main() {
    hold t = "banana"
    print(t.byteLength)
    print(t@byteAt(0))
    print(t@byteAt(5))
    print(count(view t, 97))
    hold built = "ban{"an"}a"
    print(same(view t, view built))
    hold other = "bananas"
    print(same(view t, view other))
    hold u = "año €"
    print(u.byteLength)
    print(codepoints(view u))
    print(u@byteAt(1))
    hold empty = ""
    print(empty.byteLength)
}
