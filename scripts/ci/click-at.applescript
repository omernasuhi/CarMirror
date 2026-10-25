-- Simulator'da verilen ekran noktasına tıklar (System Events).
-- Kullanım: osascript click-at.applescript <x> <y>
on run argv
    set x to (item 1 of argv) as integer
    set y to (item 2 of argv) as integer
    tell application "Simulator" to activate
    delay 0.5
    tell application "System Events"
        tell process "Simulator"
            set frontmost to true
            click at {x, y}
        end tell
    end tell
    return "Tıklandı (System Events): " & x & "," & y
end run
