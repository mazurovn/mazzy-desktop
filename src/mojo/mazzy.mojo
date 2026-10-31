# libmazzy_mojo — вычислительное ядро mazzy-shell (вызывается из Nim через C ABI).
# Сборка: mojo build --emit shared-lib -o libmazzy_mojo.so mazzy.mojo
from std.memory import UnsafePointer
from std.math import exp


# Уменьшение RGBA-картинки в 2 раза (box filter) — миниатюры окон.
@export("mz_downscale2x_rgba")
def mz_downscale2x_rgba(src: UnsafePointer[UInt8, MutAnyOrigin], w: Int32, h: Int32,
                        dst: UnsafePointer[UInt8, MutAnyOrigin]) abi("C"):
    var dw = Int(w) // 2
    var dh = Int(h) // 2
    var stride = Int(w) * 4
    for y in range(dh):
        var r0 = src + (2 * y) * stride
        var r1 = r0 + stride
        var o = dst + y * dw * 4
        for x in range(dw):
            var p = x * 8
            for c in range(4):
                var s = Int(r0[p + c]) + Int(r0[p + 4 + c]) + Int(r1[p + c]) + Int(r1[p + 4 + c])
                o[x * 4 + c] = UInt8((s + 2) >> 2)


# Раскладка карусели: для каждой карточки i при позиции pos → (x, z, угол°, яркость).
@export("mz_layout_cards")
def mz_layout_cards(n: Int32, pos: Float32, spacing: Float32, center_gap: Float32,
                    tilt: Float32, depth: Float32, par_x: Float32, mouse_par: Float32,
                    result: UnsafePointer[Float32, MutAnyOrigin]) abi("C"):
    for i in range(Int(n)):
        var d = Float32(i) - pos
        var ad = abs(d)
        var sg: Float32 = 1.0 if d > 0 else -1.0
        var m1 = min(ad, Float32(1.0))
        var x = sg * (m1 * center_gap + ad * spacing)
        var px = par_x * mouse_par * (1.0 + 0.6 * (1.0 - min(ad, Float32(3.0)) / 3.0))
        result[i * 4 + 0] = x + px
        result[i * 4 + 1] = -ad * depth
        result[i * 4 + 2] = -sg * tilt * m1
        result[i * 4 + 3] = 1.0 - 0.45 * m1


# Экспоненциальное сглаживание (пружина без перелёта).
@export("mz_smooth")
def mz_smooth(cur: Float32, target: Float32, dt: Float32, k: Float32) abi("C") -> Float32:
    return cur + (target - cur) * (1.0 - exp(-dt * k))


# Премультипликация альфы RGBA (in place) — для корректного блендинга в GL.
@export("mz_premultiply_rgba")
def mz_premultiply_rgba(px: UnsafePointer[UInt8, MutAnyOrigin], n: Int32) abi("C"):
    for i in range(Int(n)):
        var a = Int(px[i * 4 + 3])
        if a == 255:
            continue
        for c in range(3):
            px[i * 4 + c] = UInt8((Int(px[i * 4 + c]) * a + 127) // 255)


# Кадр окна из wl_shm (BGRA/XRGB, stride в байтах) → RGBA-миниатюра за один проход:
# box-фильтр k×k, перестановка каналов, альфа = 255 (окна с прозрачностью не должны просвечивать карточку).
# flip != 0 — строки читаются снизу вверх (флаг y_invert протокола). dst: (w//k) × (h//k) × 4.
@export("mz_bgra_to_rgba_fit")
def mz_bgra_to_rgba_fit(src: UnsafePointer[UInt8, MutAnyOrigin], w: Int32, h: Int32, stride: Int32,
                        dst: UnsafePointer[UInt8, MutAnyOrigin], k: Int32, flip: Int32) abi("C"):
    var kk = max(Int(k), 1)
    var dw = Int(w) // kk
    var dh = Int(h) // kk
    var st = Int(stride)
    var norm = kk * kk
    var half = norm // 2
    for y in range(dh):
        var o = dst + y * dw * 4
        var x = 0
        if kk == 2:
            # SIMD-путь для самого частого k=2: 16 байт = 4 BGRA-пикселя строки → 2 выходных пикселя.
            var sy0 = y * 2
            var sy1 = sy0 + 1
            if flip != 0:
                sy0 = Int(h) - 1 - sy0
                sy1 = Int(h) - 1 - sy1
            var r0 = src + sy0 * st
            var r1 = src + sy1 * st
            while x + 2 <= dw:
                var p0 = r0.load[width=16](x * 8).cast[DType.uint16]()
                var p1 = r1.load[width=16](x * 8).cast[DType.uint16]()
                var s16 = p0 + p1
                var lo = s16.slice[4]() + s16.slice[4, offset=4]()         # пиксель 0 + пиксель 1
                var hi = s16.slice[4, offset=8]() + s16.slice[4, offset=12]()  # пиксель 2 + пиксель 3
                var v = ((lo.join(hi) + 2) >> 2).cast[DType.uint8]()
                var rgba = v.shuffle[2, 1, 0, 3, 6, 5, 4, 7]()
                rgba[3] = 255
                rgba[7] = 255
                o.store(x * 4, rgba)
                x += 2
        while x < dw:
            var b = 0
            var g = 0
            var r = 0
            for yy in range(kk):
                var sy = y * kk + yy
                if flip != 0:
                    sy = Int(h) - 1 - sy
                var row = src + sy * st + x * kk * 4
                for xx in range(kk):
                    b += Int(row[xx * 4 + 0])
                    g += Int(row[xx * 4 + 1])
                    r += Int(row[xx * 4 + 2])
            o[x * 4 + 0] = UInt8((r + half) // norm)
            o[x * 4 + 1] = UInt8((g + half) // norm)
            o[x * 4 + 2] = UInt8((b + half) // norm)
            o[x * 4 + 3] = 255
            x += 1
