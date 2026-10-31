## Разбор событий композитора без сокета и без запуска Mango или Hyprland.
import ../seat

doAssert seatParseLine("workspace>>2").ws == 2
doAssert seatParseLine("workspace>>nope").ws == 0
doAssert seatParseLine("workspacev2>>6,6").ws == 6
doAssert seatParseLine("workspacev2>>7,web").ws == 7
doAssert seatParseLine("workspacev2>>0,1").ws == 0
doAssert DeskCount == 9
doAssert seatParseLine("activewindowv2>>ABC").focus == "0xabc"
doAssert seatParseLine("activewindowv2>>").focus == ""
doAssert seatParseLine("closewindow>>0xABC").closed == "0xabc"
let mango = """{"all_tags":[{"monitor":"eDP-1","tags":[{"index":1,"is_active":false},{"index":2,"is_active":true},{"index":3,"is_active":false}]}]}"""
let note = seatParseLine(mango)
doAssert note.ws == 2
doAssert note.focus == ""
doAssert seatParseLine("""{"all_tags":[]}""").ws == 0
doAssert seatParseLine("not-an-event").ws == 0
echo "OK seat"
