///|
fn lines_of(text : String) -> Array[String] {
  let parts = text.split("\n").map(v => v.to_owned()).to_array()
  if parts.length() > 0 && parts[parts.length() - 1] == "" {
    let _ = parts.pop()
  }
  parts
}

///|
fn join_lines(lines : Array[String]) -> String {
  if lines.length() == 0 {
    "\n"
  } else {
    lines.join("\n") + "\n"
  }
}

///|
/// Ставит Session=mango и XSession=mango внутри [User].
/// Чужие ключи и остальные секции сохраняются. Лишние XSession= убираются.
pub fn account_mango(text : String) -> String {
  let src = lines_of(text)
  let body : Array[String] = []
  for i = 0; i < src.length(); i = i + 1 {
    let line = src[i]
    if line.has_prefix("XSession=") {
      continue
    }
    body.push(line)
  }
  let mut has_user = false
  for i = 0; i < body.length(); i = i + 1 {
    if body[i] == "[User]" {
      has_user = true
    }
  }
  let lines : Array[String] = []
  let mut placed = false
  if !has_user {
    lines.push("[User]")
    lines.push("Session=mango")
    lines.push("XSession=mango")
    placed = true
  }
  let mut in_user = false
  for i = 0; i < body.length(); i = i + 1 {
    let line = body[i]
    if line.has_prefix("[") {
      if in_user && !placed {
        lines.push("Session=mango")
        lines.push("XSession=mango")
        placed = true
      }
      in_user = line == "[User]"
    }
    if line.has_prefix("Session=") {
      lines.push("Session=mango")
      if in_user && !placed {
        lines.push("XSession=mango")
        placed = true
      }
      continue
    }
    lines.push(line)
  }
  if in_user && !placed {
    lines.push("Session=mango")
    lines.push("XSession=mango")
  }
  join_lines(lines)
}

///|
/// Вставляет extra сразу после первой строки, равной needle.
pub fn insert_after(text : String, needle : String, extra : String) -> String? {
  let src = lines_of(text)
  let out : Array[String] = []
  let mut found = false
  for i = 0; i < src.length(); i = i + 1 {
    let line = src[i]
    out.push(line)
    if !found && line == needle {
      found = true
      if i + 1 >= src.length() || src[i + 1] != extra {
        out.push(extra)
      }
    }
  }
  if !found {
    None
  } else {
    Some(join_lines(out))
  }
}
