// Cross-directory standard-library import regression. Run with --lib <repo-root>.
take std.io.console

flow main() => Int {
    change reader = consoleOpen()
    hold result = consoleClose(edit reader)
    when result != 0 { give 1 }
    print("elepad-console-import-ok")
    give 0
}
