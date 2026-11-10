async fn main() {
    print(-1)
    for i in 0..100 {
        await sleepMs(5)
        print(i)
    }
}
