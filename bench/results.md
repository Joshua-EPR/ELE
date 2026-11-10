# Resultados de benchmarks

Fecha: 2026-11-08 23:07. CPU: Intel(R) Core(TM) i5-7300U CPU @ 2.60GHz. Ejecuciones por medida: 5.
Backend rustc: -C opt-level=0 (su configuración actual), rustc host: x86_64-pc-windows-gnu, release: 1.99.1. Backend cranelift: opt_level=speed.
Tiempo de compilar incluye enlazado. Pico de memoria: PeakWorkingSet64 muestreado cada 5 ms.
Reservas/realocaciones de heap y suspensiones: build cranelift aparte con --trace-alloc (allocs == frees y heap_ok=1 verificados); n/d en rustc.

| Programa | Backend | Compilar (ms) | Ejecutable (bytes) | Mediana (ms) | Mínimo (ms) | Pico memoria (KiB) | Reservas | Realocaciones | Suspensiones |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| async_create_1m | rustc | 1766 | 5194910 | 23.2 | 16.9 | 3468 | n/d | n/d | n/d |
| async_create_1m | cranelift | 186 | 9728 | 135.5 | 123.5 | 2224 | 1000002 | 0 | 0 |
| async_ready_1m | rustc | 805 | 5195610 | 60 | 54.5 | 3476 | n/d | n/d | n/d |
| async_ready_1m | cranelift | 146 | 10240 | 173.2 | 162.8 | 2224 | 1000002 | 0 | 0 |
| async_suspend_1m | rustc | 865 | 5198227 | 1150.3 | 1139.6 | 3352 | n/d | n/d | n/d |
| async_suspend_1m | cranelift | 117 | 10240 | 327 | 317.3 | 2224 | 2000002 | 0 | 1000000 |
| collatz | rustc | 652 | 5120624 | 4859 | 4388.2 | 3296 | n/d | n/d | n/d |
| collatz | cranelift | 115 | 9216 | 466.6 | 452.1 | 2196 | 0 | 0 | 0 |
| fib | rustc | 685 | 5118344 | 114 | 92.9 | 3420 | n/d | n/d | n/d |
| fib | cranelift | 130 | 9216 | 52.1 | 41.4 | 2196 | 0 | 0 | 0 |
| list_index_1m | rustc | 708 | 5125261 | 372.7 | 325.8 | 11208 | n/d | n/d | n/d |
| list_index_1m | cranelift | 128 | 9728 | 95.2 | 78.8 | 10020 | 1 | 0 | 0 |
| list_iter_1m | rustc | 648 | 5126598 | 257.2 | 225.4 | 11124 | n/d | n/d | n/d |
| list_iter_1m | cranelift | 165 | 9728 | 136.8 | 112.9 | 10020 | 1 | 0 | 0 |
| list_push_1m | rustc | 647 | 5122655 | 46 | 37.3 | 12580 | n/d | n/d | n/d |
| list_push_1m | cranelift | 105 | 9216 | 39.9 | 32.9 | 11484 | 1 | 18 | 0 |
| list_release_100k | rustc | 647 | 5124283 | 158.2 | 150.6 | 5152 | n/d | n/d | n/d |
| list_release_100k | cranelift | 135 | 9728 | 54 | 48.8 | 4076 | 50 | 750 | 0 |
| list_search_1m | rustc | 1327 | 5124373 | 705.4 | 630.2 | 12540 | n/d | n/d | n/d |
| list_search_1m | cranelift | 170 | 9728 | 131.3 | 108.6 | 11484 | 1 | 18 | 0 |
| list_text_100k | rustc | 2618 | 5133141 | 188.7 | 137.7 | 9108 | n/d | n/d | n/d |
| list_text_100k | cranelift | 133 | 9728 | 45.6 | 29.4 | 9552 | 100001 | 15 | 0 |
| primes | rustc | 2098 | 5120022 | 4301.5 | 3870.4 | 3296 | n/d | n/d | n/d |
| primes | cranelift | 133 | 9728 | 2011.3 | 1967 | 2196 | 0 | 0 | 0 |
| region_batch | rustc | 729 | 5130020 | 95.6 | 77.5 | 3648 | n/d | n/d | n/d |
| region_batch | cranelift | 121 | 9728 | 155.5 | 21.7 | 2276 | 1000 | 0 | 0 |
| region_bulk | rustc | 1060 | 5129418 | 112.6 | 101.9 | 24112 | n/d | n/d | n/d |
| region_bulk | cranelift | 198 | 9728 | 59.2 | 47.8 | 14752 | 12 | 0 | 0 |
| region_individual | rustc | 1065 | 5129418 | 115.2 | 87.7 | 3308 | n/d | n/d | n/d |
| region_individual | cranelift | 114 | 9216 | 126.8 | 67.4 | 2212 | 200000 | 0 | 0 |
| spawn_await_1m | rustc | 1227 | 5208282 | 6268.8 | 5778.6 | 3500 | n/d | n/d | n/d |
| spawn_await_1m | cranelift | 170 | 10752 | 818.4 | 714.9 | 2224 | 3000002 | 0 | 2000000 |
| spawn_cancel_1m | rustc | 1129 | 5204609 | 2438.2 | 2136.8 | 3348 | n/d | n/d | n/d |
| spawn_cancel_1m | cranelift | 198 | 10240 | 449.7 | 362.5 | 2516 | 2000002 | 0 | 0 |
| spawn_interleave_100k | rustc | 1031 | 5213818 | 1138 | 1048.9 | 43032 | n/d | n/d | n/d |
| spawn_interleave_100k | cranelift | 145 | 11776 | 259.2 | 212.4 | 32524 | 600004 | 0 | 300001 |
| sum_loop | rustc | 1042 | 5119959 | 11147.6 | 9515.3 | 8160 | n/d | n/d | n/d |
| sum_loop | cranelift | 170 | 9216 | 2089.5 | 1998.5 | 2516 | 0 | 0 | 0 |
| text_build | rustc | 2392 | 5127885 | 1412.6 | 1182.4 | 8168 | n/d | n/d | n/d |
| text_build | cranelift | 177 | 9728 | 315.8 | 245.9 | 2516 | 1000000 | 0 | 0 |
