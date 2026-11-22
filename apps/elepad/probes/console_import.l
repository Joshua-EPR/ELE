// Cross-directory standard library import probe for the autonomous driver.
// Build from the repository root:
//   ele build apps/elepad/probes/console_import.l --lib . --target pe --output elepad_console_probe.exe
//   ele build apps/elepad/probes/console_import.l --lib . --target elf --output elepad_console_probe
// The program never reads input: it validates linking and safe cleanup.
// Redirected input is supported (consoleOpen returns a noninteractive reader).
take std.io.console

flow main() => Int {
    change reader = consoleOpen()
    hold result = consoleClose(edit reader)
    when result != 0 { give 1 }
    print("elepad-std-import-ok")
    give 0
}
