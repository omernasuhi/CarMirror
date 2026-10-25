-- CarPlay penceresini ekranın sol üstüne taşır ve konumunu/boyutunu yazdırır:
-- "x y genişlik yükseklik" (ekran noktası).
on run
    tell application "System Events"
        tell process "Simulator"
            set summary to ""
            repeat with w in windows
                set summary to summary & (name of w) & " | "
            end repeat
            log "Pencereler: " & summary
            repeat with w in windows
                if (name of w) contains "CarPlay" then
                    set position of w to {40, 60}
                    delay 0.5
                    set {px, py} to position of w
                    set {sx, sy} to size of w
                    return (px as text) & " " & (py as text) & " " & (sx as text) & " " & (sy as text)
                end if
            end repeat
        end tell
    end tell
    error "CarPlay penceresi bulunamadı"
end run
