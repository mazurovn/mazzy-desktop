## Проверка ядра mz_bgra_to_rgba_fit (libmazzy_mojo): корректность каналов/размера и время на 1920×1080.
## Сборка: nim c -d:release -d:MojoDir=$HOME/.local/lib/mazzy -r tests/test_fit.nim
import std/[times, strformat]
const MojoDir {.strdefine.}: string = ""
{.passL: "-L" & MojoDir & " -lmazzy_mojo -Wl,-rpath," & MojoDir.}
proc mz_bgra_to_rgba_fit(src: ptr uint8, w, h, stride: int32, dst: ptr uint8, k, flip: int32) {.importc, cdecl.}

proc check(cond: bool, msg: string) =
  if not cond: quit("FAIL: " & msg, 1)

# 1) точность: 4×2, k=2 → 2×1; BGRA-пиксели
var src = newSeq[uint8](4 * 2 * 4 + 8)   # stride с хвостом 8 байт
let stride = 4 * 4 + 8
proc put(x, y: int, b, g, r, a: uint8) =
  let o = y * stride + x * 4
  src[o] = b; src[o+1] = g; src[o+2] = r; src[o+3] = a
put(0, 0, 10, 20, 30, 0); put(1, 0, 10, 20, 30, 0); put(0, 1, 10, 20, 30, 0); put(1, 1, 10, 20, 30, 0)
put(2, 0, 0, 0, 255, 255); put(3, 0, 0, 0, 255, 255); put(2, 1, 0, 0, 0, 255); put(3, 1, 0, 0, 0, 255)
var dst = newSeq[uint8](2 * 1 * 4)
mz_bgra_to_rgba_fit(addr src[0], 4, 2, stride.int32, addr dst[0], 2, 0)
check(dst[0..3] == @[30'u8, 20, 10, 255], &"px0 rgba={dst[0..3]}")        # r,g,b переставлены, alpha=255
check(dst[4..7] == @[128'u8, 0, 0, 255], &"px1 rgba={dst[4..7]}")         # (255+255+0+0+2)//4 = 128
# flip: строки снизу вверх — результат для k=2 тот же набор, порядок строк внутри блока не влияет
mz_bgra_to_rgba_fit(addr src[0], 4, 2, stride.int32, addr dst[0], 2, 1)
check(dst[4..7] == @[128'u8, 0, 0, 255], "flip")
# k=1: чистая конверсия
var d1 = newSeq[uint8](4 * 2 * 4)
mz_bgra_to_rgba_fit(addr src[0], 4, 2, stride.int32, addr d1[0], 1, 1)
check(d1[0..3] == @[30'u8, 20, 10, 255] and d1[(2 + 4) * 4 + 0] == 255, "k=1 flip: нижняя строка src → верхняя dst")

# 2) время: 1920×1080 → k=2 (960×540) и k=3
for k in [2'i32, 3]:
  var big = newSeq[uint8](1920 * 1080 * 4)
  for i in 0 ..< big.len: big[i] = uint8(i and 255)
  var outp = newSeq[uint8]((1920 div k) * (1080 div k) * 4)
  let t0 = cpuTime()
  for i in 0 ..< 10: mz_bgra_to_rgba_fit(addr big[0], 1920, 1080, 1920 * 4, addr outp[0], k, 0)
  echo &"1920x1080 k={k}: {(cpuTime() - t0) * 100:.2f} ms/кадр"
echo "OK"
