-- Simulator uygulamasında I/O → External Displays → CarPlay menüsünü seçer.
-- Yalnızca Xcode 26 ve öncesindeki Simulator.app'te bulunur (Xcode 27'de kaldırıldı).
on run
    tell application "Simulator" to activate
    delay 2
    tell application "System Events"
        tell process "Simulator"
            set frontmost to true
            set menuNames to name of every menu bar item of menu bar 1
            log "Menüler: " & (menuNames as text)
            set ioMenu to missing value
            repeat with candidate in {"I/O", "IO", "Hardware"}
                if menuNames contains (candidate as text) then
                    set ioMenu to menu bar item (candidate as text) of menu bar 1
                    exit repeat
                end if
            end repeat
            if ioMenu is missing value then error "I/O menüsü bulunamadı"

            click ioMenu
            delay 0.5
            set displaysItem to menu item "External Displays" of menu 1 of ioMenu
            click displaysItem
            delay 0.5
            set itemNames to name of every menu item of menu 1 of displaysItem
            log "External Displays: " & (itemNames as text)

            set carPlayItem to missing value
            repeat with itemName in itemNames
                if (itemName as text) is "CarPlay" then
                    set carPlayItem to menu item "CarPlay" of menu 1 of displaysItem
                    exit repeat
                end if
            end repeat
            if carPlayItem is missing value then
                repeat with itemName in itemNames
                    if (itemName as text) starts with "CarPlay" then
                        set carPlayItem to menu item (itemName as text) of menu 1 of displaysItem
                        exit repeat
                    end if
                end repeat
            end if
            if carPlayItem is missing value then error "CarPlay menü öğesi bulunamadı"
            click carPlayItem
        end tell
    end tell
    return "CarPlay ekranı açıldı"
end run
