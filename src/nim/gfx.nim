## Рендер GLES2 для mazzy-shell: шейдер «карточка» (текстура, скругление, рамка,
## затемнение, тень, градиенты), матрицы, текстуры, текст через pangocairo.
import math, wl

type
  Mat4* = array[16, float32]   # column-major
  Tex* = object
    id*: GLuint
    w*, h*: int

proc identity*(): Mat4 =
  result[0] = 1; result[5] = 1; result[10] = 1; result[15] = 1

proc mul*(a, b: Mat4): Mat4 =
  for c in 0..3:
    for r in 0..3:
      var s = 0'f32
      for k in 0..3: s += a[k*4 + r] * b[c*4 + k]
      result[c*4 + r] = s

proc translate*(x, y, z: float32): Mat4 =
  result = identity(); result[12] = x; result[13] = y; result[14] = z

proc scale*(x, y: float32): Mat4 =
  result = identity(); result[0] = x; result[5] = y

proc rotateY*(deg: float32): Mat4 =
  let a = deg * PI / 180; let c = cos(a).float32; let s = sin(a).float32
  result = identity(); result[0] = c; result[2] = -s; result[8] = s; result[10] = c

proc rotateZ*(deg: float32): Mat4 =
  ## Поворот в плоскости экрана. 0 — вверх, положительный угол по часовой.
  let a = deg * PI / 180; let c = cos(a).float32; let s = sin(a).float32
  result = identity(); result[0] = c; result[1] = s; result[4] = -s; result[5] = c

## Перспектива в пиксельных координатах: центр экрана = (0,0), ось Y вниз,
## фокусное расстояние f (px), объекты на z<0 дальше.
proc perspectivePx*(w, h, f: float32): Mat4 =
  let near = 10'f32; let far = 8000'f32
  # proj: x' = x*f/(f - z)  →  NDC = x'/(w/2)
  result[0] = 2*f / w
  result[5] = -2*f / h
  result[10] = -(far + near) / (far - near)
  result[11] = -1
  result[14] = -2*far*near / (far - near)
  # сдвиг «камеры» на f по z: умножаем на translate(0,0,-f) при использовании

const vertSrc = """
attribute vec2 a_pos;
uniform mat4 u_mvp;
uniform vec2 u_size;
varying vec2 v_uv;
varying vec2 v_px;
void main() {
  v_uv = a_pos;
  v_px = a_pos * u_size;
  vec4 p = vec4((a_pos - 0.5) * u_size, 0.0, 1.0);
  gl_Position = u_mvp * p;
}
"""
const fragSrc = """
precision highp float;
varying vec2 v_uv;
varying vec2 v_px;
uniform sampler2D u_tex;
uniform vec2 u_size;
uniform float u_radius;
uniform float u_dim;       // 1 = как есть, <1 темнее
uniform float u_alpha;
uniform int u_mode;        // 0 текстура, 1 плоский цвет, 2 тень, 3 свечение, 4 отражение, 5 значок: альфа текстуры, цвет из u_color
uniform vec4 u_color;
uniform float u_border;    // ширина рамки px (0 — нет)
uniform vec4 u_border_color;
uniform float u_flip;      // 1 — перевернуть по Y (отражение)
float sdRound(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
void main() {
  vec2 hs = u_size * 0.5;
  vec2 p = v_px - hs;
  float d = sdRound(p, hs, u_radius);
  if (u_mode == 2) {               // мягкая тень
    float a = 1.0 - smoothstep(-u_radius * 2.0, u_radius * 2.0, d);
    gl_FragColor = vec4(u_color.rgb * u_color.a * a * u_alpha, u_color.a * a * u_alpha);
    return;
  }
  if (u_mode == 3) {               // свечение
    float r = length((v_uv - 0.5) * 2.0);
    float a = (1.0 - smoothstep(0.0, 1.0, r)) * u_color.a * u_alpha;
    gl_FragColor = vec4(u_color.rgb * a, a);
    return;
  }
  float cov = 1.0 - smoothstep(-0.8, 0.8, d);
  vec4 c;
  if (u_mode == 1) c = vec4(u_color.rgb * u_color.a, u_color.a);
  else if (u_mode == 5) {
    vec2 uv = v_uv; if (u_flip > 0.5) uv.y = 1.0 - uv.y;
    float mask = texture2D(u_tex, uv).a;
    float a = mask * u_color.a;
    c = vec4(u_color.rgb * u_dim * a, a);
  } else {
    vec2 uv = v_uv; if (u_flip > 0.5) uv.y = 1.0 - uv.y;
    c = texture2D(u_tex, uv);
    c.rgb *= u_dim;
  }
  if (u_mode == 4) c *= (1.0 - v_uv.y);   // отражение гаснет вниз
  if (u_border > 0.0) {
    float b = smoothstep(-u_border - 0.8, -u_border + 0.8, d);
    c = mix(c, u_border_color, b);
  }
  float a = c.a * cov * u_alpha;
  gl_FragColor = vec4(c.rgb * cov * u_alpha, a);
}
"""

type Gfx* = object
  prog*: GLuint
  vbo: GLuint
  aPos: GLint
  uMvp, uSize, uTex, uRadius, uDim, uAlpha, uMode, uColor, uBorder, uBorderColor, uFlip: GLint
  white*: Tex

proc compile(t: GLenum, src: string): GLuint =
  result = glCreateShader(t)
  var s = src.cstring
  glShaderSource(result, 1, addr s, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, addr ok)
  if ok == 0:
    var log = newString(2048); var n: GLsizei
    glGetShaderInfoLog(result, 2048, addr n, log.cstring)
    raise newException(ValueError, "shader: " & log[0 ..< n])

proc newTex*(w, h: int, fmt: GLenum, data: pointer, mip = false): Tex =
  result.w = w; result.h = h
  glGenTextures(1, addr result.id)
  glBindTexture(GL_TEXTURE_2D, result.id)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  glTexImage2D(GL_TEXTURE_2D, 0, fmt.GLint, w.GLsizei, h.GLsizei, 0, fmt, GL_UNSIGNED_BYTE, data)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  if mip:
    glGenerateMipmap(GL_TEXTURE_2D)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  else:
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)

proc free*(t: var Tex) =
  if t.id != 0: glDeleteTextures(1, addr t.id); t.id = 0

proc initGfx*(): Gfx =
  let vs = compile(GL_VERTEX_SHADER, vertSrc)
  let fs = compile(GL_FRAGMENT_SHADER, fragSrc)
  result.prog = glCreateProgram()
  glAttachShader(result.prog, vs); glAttachShader(result.prog, fs)
  glLinkProgram(result.prog)
  var ok: GLint
  glGetProgramiv(result.prog, GL_LINK_STATUS, addr ok)
  if ok == 0:
    var log = newString(2048); var n: GLsizei
    glGetProgramInfoLog(result.prog, 2048, addr n, log.cstring)
    raise newException(ValueError, "link: " & log[0 ..< n])
  glUseProgram(result.prog)
  result.aPos = glGetAttribLocation(result.prog, "a_pos")
  template u(n: string): GLint = glGetUniformLocation(result.prog, n)
  result.uMvp = u"u_mvp"; result.uSize = u"u_size"; result.uTex = u"u_tex"; result.uRadius = u"u_radius"
  result.uDim = u"u_dim"; result.uAlpha = u"u_alpha"; result.uMode = u"u_mode"; result.uColor = u"u_color"
  result.uBorder = u"u_border"; result.uBorderColor = u"u_border_color"; result.uFlip = u"u_flip"
  var quad = [0'f32, 0, 1, 0, 0, 1, 1, 1]
  glGenBuffers(1, addr result.vbo)
  glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
  glBufferData(GL_ARRAY_BUFFER, sizeof(quad), addr quad[0], GL_STATIC_DRAW)
  glEnableVertexAttribArray(result.aPos.GLuint)
  glVertexAttribPointer(result.aPos.GLuint, 2, GL_FLOAT, GL_FALSE, 0, nil)
  var px = [255'u8, 255, 255, 255]
  result.white = newTex(1, 1, GL_RGBA, addr px[0])
  glUniform1i(result.uTex, 0)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)   # premultiplied

type DrawParams* = object
  mvp*: Mat4
  size*: (float32, float32)
  tex*: GLuint
  radius*, dim*, alpha*, border*, flip*: float32
  mode*: int32
  color*, borderColor*: (float32, float32, float32, float32)

proc draw*(g: Gfx, p: DrawParams) =
  var m = p.mvp
  glUniformMatrix4fv(g.uMvp, 1, GL_FALSE, addr m[0])
  glUniform2f(g.uSize, p.size[0], p.size[1])
  glUniform1f(g.uRadius, p.radius); glUniform1f(g.uDim, p.dim); glUniform1f(g.uAlpha, p.alpha)
  glUniform1i(g.uMode, p.mode); glUniform1f(g.uBorder, p.border); glUniform1f(g.uFlip, p.flip)
  glUniform4f(g.uColor, p.color[0], p.color[1], p.color[2], p.color[3])
  glUniform4f(g.uBorderColor, p.borderColor[0], p.borderColor[1], p.borderColor[2], p.borderColor[3])
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, if p.tex == 0: g.white.id else: p.tex)
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)

proc params*(): DrawParams =
  result.dim = 1; result.alpha = 1; result.color = (1'f32, 1'f32, 1'f32, 1'f32); result.borderColor = (1'f32, 1'f32, 1'f32, 0.3'f32)

# ---- текст через pangocairo → RGBA (premultiplied ARGB32 у cairo → меняем каналы)
{.passC: staticExec("pkg-config --cflags pangocairo cairo").}
{.passL: staticExec("pkg-config --libs pangocairo cairo").}
type
  cairo_surface_t {.importc: "cairo_surface_t", header: "<cairo.h>", incompleteStruct.} = object
  cairo_t {.importc: "cairo_t", header: "<cairo.h>", incompleteStruct.} = object
  PangoLayout {.importc: "PangoLayout", header: "<pango/pangocairo.h>", incompleteStruct.} = object
  PangoFontDescription {.importc: "PangoFontDescription", header: "<pango/pango.h>", incompleteStruct.} = object
  PangoRectangle {.importc: "PangoRectangle", header: "<pango/pango.h>".} = object
    x, y, width, height: cint
const CAIRO_FORMAT_ARGB32 = 0'i32
proc cairo_image_surface_create(fmt: int32, w, h: cint): ptr cairo_surface_t {.importc, header: "<cairo.h>".}
proc cairo_image_surface_get_data(s: ptr cairo_surface_t): ptr UncheckedArray[uint8] {.importc, header: "<cairo.h>".}
proc cairo_image_surface_get_stride(s: ptr cairo_surface_t): cint {.importc, header: "<cairo.h>".}
proc cairo_surface_flush(s: ptr cairo_surface_t) {.importc, header: "<cairo.h>".}
proc cairo_surface_destroy(s: ptr cairo_surface_t) {.importc, header: "<cairo.h>".}
proc cairo_create(s: ptr cairo_surface_t): ptr cairo_t {.importc, header: "<cairo.h>".}
proc cairo_destroy(c: ptr cairo_t) {.importc, header: "<cairo.h>".}
proc cairo_set_source_rgba(c: ptr cairo_t, r, g, b, a: cdouble) {.importc, header: "<cairo.h>".}
proc cairo_move_to(c: ptr cairo_t, x, y: cdouble) {.importc, header: "<cairo.h>".}
proc pango_cairo_create_layout(c: ptr cairo_t): ptr PangoLayout {.importc, header: "<pango/pangocairo.h>".}
proc pango_cairo_show_layout(c: ptr cairo_t, l: ptr PangoLayout) {.importc, header: "<pango/pangocairo.h>".}
proc pango_layout_set_text(l: ptr PangoLayout, t: cstring, len: cint) {.importc, header: "<pango/pango.h>".}
proc pango_layout_set_width(l: ptr PangoLayout, w: cint) {.importc, header: "<pango/pango.h>".}
proc pango_layout_set_alignment(l: ptr PangoLayout, a: cint) {.importc, header: "<pango/pango.h>".}
proc pango_layout_set_ellipsize(l: ptr PangoLayout, e: cint) {.importc, header: "<pango/pango.h>".}
proc pango_layout_set_font_description(l: ptr PangoLayout, d: ptr PangoFontDescription) {.importc, header: "<pango/pango.h>".}
proc pango_layout_get_pixel_extents(l: ptr PangoLayout, ink, logical: ptr PangoRectangle) {.importc, header: "<pango/pango.h>".}
proc pango_font_description_from_string(s: cstring): ptr PangoFontDescription {.importc, header: "<pango/pango.h>".}
proc pango_font_description_free(d: ptr PangoFontDescription) {.importc, header: "<pango/pango.h>".}
proc g_object_unref(o: pointer) {.importc, header: "<glib-object.h>".}
const
  PANGO_ELLIPSIZE_END = 3'i32
  PANGO_SCALE = 1024

## Рендер строки в текстуру фиксированной ширины. align: 0 слева, 1 центр, 2 справа.
## Центр по умолчанию — часы, цифры листов и подписи дока.
proc textTex*(text, font: string, width: int, alpha = 1.0, align = 1): Tex =
  let tmp = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 4, 4)
  let cr0 = cairo_create(tmp)
  let lay = pango_cairo_create_layout(cr0)
  let fd = pango_font_description_from_string(font.cstring)
  pango_layout_set_font_description(lay, fd)
  pango_layout_set_width(lay, cint(width * PANGO_SCALE))
  let alignTo = if align < 0: 0 elif align > 2: 2 else: align
  pango_layout_set_alignment(lay, cint(alignTo))
  pango_layout_set_ellipsize(lay, PANGO_ELLIPSIZE_END)
  pango_layout_set_text(lay, text.cstring, cint(text.len))
  var ink, logical: PangoRectangle
  pango_layout_get_pixel_extents(lay, addr ink, addr logical)
  let h = max(4, logical.height + 4)
  let surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, cint(width), cint(h))
  let cr = cairo_create(surf)
  cairo_set_source_rgba(cr, 1, 1, 1, alpha)
  cairo_move_to(cr, 0, 2)
  pango_cairo_show_layout(cr, lay)
  cairo_surface_flush(surf)
  # cairo: BGRA premultiplied (little-endian ARGB32) → RGBA
  let data = cairo_image_surface_get_data(surf)
  let stride = cairo_image_surface_get_stride(surf).int
  var rgba = newSeq[uint8](width * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< width:
      let s = y * stride + x * 4; let d = (y * width + x) * 4
      rgba[d] = data[s + 2]; rgba[d + 1] = data[s + 1]; rgba[d + 2] = data[s]; rgba[d + 3] = data[s + 3]
  result = newTex(width, h, GL_RGBA, addr rgba[0])
  g_object_unref(lay); pango_font_description_free(fd)
  cairo_destroy(cr); cairo_surface_destroy(surf); cairo_destroy(cr0); cairo_surface_destroy(tmp)
