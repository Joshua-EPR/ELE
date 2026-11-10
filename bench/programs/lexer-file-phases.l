fn profileFile(path: &Text) -> Int {
    match readText(path, 16 * 1024 * 1024) {
        Ok(source) => {
            print("@scan")
            let scanned = lexSource(source)
            print("@emit")
            match scanned {
                Ok(tokens) => {
                    emitTokens(tokens)
                    print("@end")
                    return 0
                }
                Err(code) => { return 6 }
            }
        }
        Err(code) => { return 4 }
    }
}

fn main() -> Int {
    match processArg(0) {
        Ok(path) => { return profileFile(path) }
        Err(code) => { return 2 }
    }
}
