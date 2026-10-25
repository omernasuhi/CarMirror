-- CarPlay penceresini öne getirip ekranın sol üstüne taşır, ardından
-- pencerenin ve içindeki arayüz öğelerinin konum/boyutlarını yazdırır:
--   WINDOW x y genişlik yükseklik
--   ELEMENT x y genişlik yükseklik rol
-- (ekran noktası, sol üst orijin)
on rectText(itemPosition, itemSize)
    return ((item 1 of itemPosition) as integer as text) & " " & ((item 2 of itemPosition) as integer as text) & " " & ((item 1 of itemSize) as integer as text) & " " & ((item 2 of itemSize) as integer as text)
end rectText

on run
    tell application "Simulator" to activate
    delay 1
    tell application "System Events"
        tell process "Simulator"
            set frontmost to true
            set summary to ""
            repeat with w in windows
                set summary to summary & (name of w) & " | "
            end repeat
            log "Pencereler: " & summary
            repeat with w in windows
                if (name of w) contains "CarPlay" then
                    set position of w to {40, 60}
                    delay 0.5
                    try
                        perform action "AXRaise" of w
                    end try
                    delay 0.5
                    set output to "WINDOW " & my rectText(position of w, size of w)
                    try
                        repeat with e in (entire contents of w)
                            try
                                set output to output & linefeed & "ELEMENT " & my rectText(position of e, size of e) & " " & (role of e as text)
                            end try
                        end repeat
                    end try
                    return output
                end if
            end repeat
        end tell
    end tell
    error "CarPlay penceresi bulunamadı"
end run
