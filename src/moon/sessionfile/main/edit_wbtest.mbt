///|
test "xsession встаёт сразу за Session внутри User" {
  let src =
    #|[User]
    #|Session=hyprland
    #|Icon=/home/a
    #|SystemAccount=false
    #|
    #|[InputSource0]
    #|xkb=us
    #|
  inspect(
    account_mango(src),
    content=(
      #|[User]
      #|Session=mango
      #|XSession=mango
      #|Icon=/home/a
      #|SystemAccount=false
      #|
      #|[InputSource0]
      #|xkb=us
      #|
    ),
  )
}

///|
test "хвостовой XSession переносится в User" {
  let src =
    #|[User]
    #|Session=hyprland
    #|Icon=/home/a
    #|
    #|[InputSource1]
    #|xkb=ru
    #|XSession=mango
    #|
  inspect(
    account_mango(src),
    content=(
      #|[User]
      #|Session=mango
      #|XSession=mango
      #|Icon=/home/a
      #|
      #|[InputSource1]
      #|xkb=ru
      #|
    ),
  )
}

///|
test "повторный прогон не дублирует XSession" {
  let src =
    #|[User]
    #|Session=mango
    #|XSession=mango
    #|Icon=/home/a
    #|
  inspect(
    account_mango(src),
    content=(
      #|[User]
      #|Session=mango
      #|XSession=mango
      #|Icon=/home/a
      #|
    ),
  )
}

///|
test "без секции User она добавляется сверху" {
  let src =
    #|Icon=/home/a
    #|
  inspect(
    account_mango(src),
    content=(
      #|[User]
      #|Session=mango
      #|XSession=mango
      #|Icon=/home/a
      #|
    ),
  )
}

///|
test "в User нет Session — ключи дописываются перед следующей секцией" {
  let src =
    #|[User]
    #|Icon=/home/a
    #|
    #|[InputSource0]
    #|xkb=us
    #|
  inspect(
    account_mango(src),
    content=(
      #|[User]
      #|Icon=/home/a
      #|
      #|Session=mango
      #|XSession=mango
      #|[InputSource0]
      #|xkb=us
      #|
    ),
  )
}

///|
test "insert_after вставляет одну строку" {
  let src =
    #|export XDG_CURRENT_DESKTOP=sway
    #|exec sway
    #|
  let extra = "systemctl --user unmask --runtime dms.service hypridle.service >/dev/null 2>&1 || true"
  let got = match insert_after(src, "export XDG_CURRENT_DESKTOP=sway", extra) {
    Some(text) => text
    None => panic()
  }
  inspect(
    got,
    content=(
      #|export XDG_CURRENT_DESKTOP=sway
      #|systemctl --user unmask --runtime dms.service hypridle.service >/dev/null 2>&1 || true
      #|exec sway
      #|
    ),
  )
}

///|
test "insert_after повторно не дублирует строку" {
  let once =
    #|export XDG_CURRENT_DESKTOP=sway
    #|systemctl --user unmask --runtime dms.service hypridle.service >/dev/null 2>&1 || true
    #|exec sway
    #|
  let extra = "systemctl --user unmask --runtime dms.service hypridle.service >/dev/null 2>&1 || true"
  let got = match insert_after(once, "export XDG_CURRENT_DESKTOP=sway", extra) {
    Some(text) => text
    None => panic()
  }
  inspect(got, content=once)
}

///|
test "insert_after без строки даёт None" {
  inspect(
    insert_after("exec sway\n", "нет такой", "x") is None,
    content="true",
  )
}
