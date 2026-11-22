// Resource audit for Window: 200 open/draw/close cycles, then one window
// stays open so tests/native_backend/win64_window_resources.ps1 can count
// this process's GDI and USER objects before closing it with WM_CLOSE.
take std.ui.window

flow main() => Int {
    hold title = "ELE churn"
    hold mark = "x"
    change i = 0
    during i < 200 {
        hold w = windowOpen(title, 160, 120)
        when windowStatus(w) != 0 {
            windowClose(w)
            give 10
        }
        windowFill(w, 0, 0, 10, 10, 255)
        windowText(w, 1, 1, mark, 0)
        when windowClose(w) != 0 { give 11 }
        i += 1
    }
    hold last = windowOpen(title, 160, 120)
    when windowStatus(last) != 0 {
        windowClose(last)
        give 12
    }
    print("churn-done")
    change reader = windowReader()
    during true {
        hold ev = windowEvent(last, edit reader)
        when ev.kind == WINDOW_CLOSE || ev.kind == WINDOW_ERROR { leave }
    }
    give windowClose(last)
}
