// Comparison Benchmark: fibonacci_recursive.c
#include <stdio.h>
#include <stdint.h>

int64_t fib(int64_t n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    int64_t res = fib(25);
    printf("%lld\n", (long long)res);
    return 0;
}
