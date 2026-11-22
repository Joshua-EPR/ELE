// Window on a target without a graphical backend (Linux today): windowOpen
// must report -7 instead of pretending, every operation on that Window
// reports -6, and closing it is 0. Prints window-unavailable-ok.
flow main() => Int {
    hold title = "headless"
    hold w = windowOpen(title, 200, 100)
    hold status = windowStatus(w)
    hold next = windowNext(w)
    hold fill = windowFill(w, 0, 0, 1, 1, 0)
    hold label = "x"
    hold text = windowText(w, 0, 0, label, 0)
    hold present = windowPresent(w)
    hold sent = windowSend(w, 16, 0, 0)
    hold pixel = windowPixel(w, 0, 0)
    hold closed = windowClose(w)
    when status != -7 { give 10 }
    when next != -6 || fill != -6 || text != -6 || present != -6 || sent != -6 || pixel != -6 { give 11 }
    when closed != 0 { give 12 }
    print("window-unavailable-ok")
    give 0
}
