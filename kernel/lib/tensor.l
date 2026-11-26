// Tensores 2D (filas x columnas) en f32 o f64, sobre una arena.
//
// Descriptor (96 bytes, alineado a 64):
//   +0 datos (alineados a 64)   +8 filas   +16 columnas
//   +24 bytes por elemento (4 = f32, 8 = f64)
//   +32 tensor del gradiente (mismo tamaño y tipo) o 0
//   +40 paso entre filas, en elementos (>= columnas: vistas)
// Las operaciones se escriben una vez sobre tLeer/tEscribir (Float): así
// el mismo código corre en f32 (entrenamiento) y en f64 (verificación de
// gradientes contra diferencias finitas). Lo caro (SGEMM, exp/tanh) tiene
// además su camino SSE para f32.
//
// Arena: bloques de 2 MiB del montón, reparto lineal alineado a 64 bytes,
// con marca/vuelta para temporales. La interfaz (reservar, marca, volver)
// es la que tendrá la arena de NEXO.

take nucleo.cpu
take nucleo.mem
take mem.monton

expose fixed F32 = 4
expose fixed F64 = 8
fixed BLOQUE = 2097152

// Arena: +0 bloque actual, +8 siguiente libre, +16 fin del bloque,
// +24 bytes reservados en total.
flow arena() => Int { give reservar(32, 8) }

expose flow arenaReservar(bytes: Int) => Int {
    hold a = arena()
    hold tam = (bytes + 63) & (~63)
    change p = leer64(a + 8)
    when leer64(a) == 0 || p + tam > leer64(a + 16) {
        change bloque = BLOQUE
        when tam + 64 > bloque { bloque = tam + 64 }
        hold base = montonReservar(bloque)
        when base == 0 { give 0 }
        escribir64(a, base)
        p = (base + 63) & (~63)
        escribir64(a + 16, base + bloque)
    }
    escribir64(a + 8, p + tam)
    escribir64(a + 24, leer64(a + 24) + tam)
    give p
}

// Marca para liberar temporales de golpe (solo dentro del mismo bloque).
expose flow arenaMarca() => Int { give leer64(arena() + 8) }
expose flow arenaVolver(marca: Int) {
    hold a = arena()
    when marca >= leer64(a) && marca <= leer64(a + 16) { escribir64(a + 8, marca) }
}
expose flow arenaUsada() => Int { give leer64(arena() + 24) }

flow ceros(dir: Int, bytes: Int) {
    change i = 0
    during i + 8 <= bytes {
        escribir64(dir + i, 0)
        i += 8
    }
    during i < bytes {
        escribir8(dir + i, 0)
        i += 1
    }
}

// Tensor nuevo a ceros. con_gradiente: crea también su gradiente.
expose flow tNuevo(filas: Int, columnas: Int, tipo: Int, con_gradiente: Bool) => Int {
    hold t = arenaReservar(64)
    hold paso = (columnas + 15) & (~15)
    hold bytes = filas * paso * tipo
    hold datos = arenaReservar(bytes)
    when t == 0 || datos == 0 { give 0 }
    ceros(datos, bytes)
    escribir64(t, datos)
    escribir64(t + 8, filas)
    escribir64(t + 16, columnas)
    escribir64(t + 24, tipo)
    escribir64(t + 32, 0)
    escribir64(t + 40, paso)
    when con_gradiente { escribir64(t + 32, tNuevo(filas, columnas, tipo, false)) }
    give t
}

expose flow tFilas(t: Int) => Int { give leer64(t + 8) }
expose flow tColumnas(t: Int) => Int { give leer64(t + 16) }
expose flow tTipo(t: Int) => Int { give leer64(t + 24) }
expose flow tGrad(t: Int) => Int { give leer64(t + 32) }
expose flow tDatos(t: Int) => Int { give leer64(t) }
expose flow tPaso(t: Int) => Int { give leer64(t + 40) }

expose flow tDir(t: Int, i: Int, j: Int) => Int {
    give leer64(t) + (i * leer64(t + 40) + j) * leer64(t + 24)
}

expose flow tLeer(t: Int, i: Int, j: Int) => Float {
    hold d = tDir(t, i, j)
    when leer64(t + 24) == F32 { give leerF32(d) }
    give floatDeBits(leer64(d))
}

expose flow tEscribir(t: Int, i: Int, j: Int, v: Float) {
    hold d = tDir(t, i, j)
    when leer64(t + 24) == F32 {
        escribirF32(d, v)
    } otherwise {
        escribir64(d, bitsDeFloat(v))
    }
}

expose flow tSumar(t: Int, i: Int, j: Int, v: Float) {
    tEscribir(t, i, j, tLeer(t, i, j) + v)
}

expose flow tCeros(t: Int) {
    ceros(leer64(t), leer64(t + 8) * leer64(t + 40) * leer64(t + 24))
}

expose flow tCerosGrad(t: Int) {
    when tGrad(t) != 0 { tCeros(tGrad(t)) }
}

expose flow tCopiar(origen: Int, destino: Int) {
    each i among 0..tFilas(origen) {
        each j among 0..tColumnas(origen) { tEscribir(destino, i, j, tLeer(origen, i, j)) }
    }
}
