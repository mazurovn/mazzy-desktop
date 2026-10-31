///|
extern "c" fn c_exit(code : Int32) = "exit"

///|
fn halt(code : Int32) -> Unit {
  c_exit(code)
}

///|
fn usage() -> Unit {
  println(
    "mazzy-sessionfile account-mango ФАЙЛ\nmazzy-sessionfile insert-after ФАЙЛ СТРОКА НОВАЯ",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() < 3 {
    usage()
    halt(2)
  }
  let cmd = args[1]
  let path = args[2]
  try {
    if cmd == "account-mango" && args.length() == 3 {
      let text = @fs.read_file_to_string(path)
      @fs.write_string_to_file(path, account_mango(text))
    } else if cmd == "insert-after" && args.length() == 5 {
      let text = @fs.read_file_to_string(path)
      match insert_after(text, args[3], args[4]) {
        Some(next) => @fs.write_string_to_file(path, next)
        None => {
          println("строка не найдена: " + args[3])
          halt(1)
        }
      }
    } else {
      usage()
      halt(2)
    }
  } catch {
    _ => {
      println(
        "не удалось прочитать или записать " + path,
      )
      halt(1)
    }
  }
}
