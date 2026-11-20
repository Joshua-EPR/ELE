// Comparison Benchmark: arithmetic_loop.c
#include <stdio.h>
#include <stdint.h>

int64_t compute(int64_t limit) {
    int64_t acc = 0;
    int64_t i = 0;
    while (i < limit) {
        acc += i * 3 + 1;
        i += 1;
    }
    return acc;
}

int main(void) {
    int64_t sum = compute(10000000);
    printf("%lld\n", (long long)sum);
    return 0;
}
