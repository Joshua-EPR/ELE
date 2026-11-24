// List of[List of[Int]]: a triangle built row by row.
flow triangle(n: Int) => List of[List of[Int]] {
    change rows: List of[List of[Int]] = List[]
    each r among 0..n {
        change row: List of[Int] = List[]
        each c among 0..(r + 1) {
            when c == 0 || c == r {
                row@push(1)
            } otherwise {
                row@push(rows[r - 1][c - 1] + rows[r - 1][c])
            }
        }
        rows@push(row)
    }
    give rows
}

flow main() {
    hold t = triangle(10)
    print(t.length)
    print(t[9].length)
    print(t[9][4])
    change line = ""
    each v among t[6] {
        line = "{line}{v} "
    }
    print(line)
}
