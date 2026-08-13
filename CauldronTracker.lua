local addonName, ns = ...

local function Today()
    return date("%Y-%m-%d")
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Cauldron]|r " .. msg)
end

local DEBUG_LOG_MAX = 500  -- keep the most recent N log entries
-- Stamp includes the date (multi-night logs replay correctly) and GetTime()
-- with millisecond precision (sub-second dedup decisions can be reconstructed).
local function DebugPrint(msg)
    if not CauldronTrackerDB then return end
    CauldronTrackerDB.debugLog = CauldronTrackerDB.debugLog or {}
    table.insert(CauldronTrackerDB.debugLog,
        string.format("%s %.3f %s", date("%Y-%m-%d %H:%M:%S"), GetTime(), msg))
    if #CauldronTrackerDB.debugLog > DEBUG_LOG_MAX then
        table.remove(CauldronTrackerDB.debugLog, 1)
    end
end

local function StripRealm(name)
    if not name then return name end
    return (strsplit("-", name, 2))
end

-- While a cauldron window is active, all writes stay anchored to the day the
-- window opened — a raid that crosses midnight doesn't split its counts
-- across two days. (State lives with the detection code further down.)
local cauldronActiveUntil = 0
local activeDayKey

local function CurrentDayKey()
    if activeDayKey and GetTime() < cauldronActiveUntil then
        return activeDayKey
    end
    return Today()
end
ns.CurrentDayKey = CurrentDayKey

local function GetTodayData()
    local today = CurrentDayKey()
    if not CauldronTrackerDB[today] then
        CauldronTrackerDB[today] = { counts = {}, cauldrons = {} }
    end
    -- Migrate old format (flat player counts)
    if not CauldronTrackerDB[today].counts then
        local old = CauldronTrackerDB[today]
        CauldronTrackerDB[today] = { counts = old, cauldrons = {} }
    end
    return CauldronTrackerDB[today]
end

local function GetTodayCounts()
    return GetTodayData().counts
end

local function GetTodayCauldrons()
    return GetTodayData().cauldrons
end

-- All cauldron output items (flasks, potions, draughts) start with "Fleeting".
-- Matching the prefix captures the full set rather than just flasks/phials.
local function IsFleetingItem(itemLink)
    if not itemLink then return false end
    local name = C_Item.GetItemNameByID(itemLink) or C_Item.GetItemInfo(itemLink)
    if not name then
        name = itemLink:match("%[(.-)%]")
    end
    if not name then return false end
    return name:lower():find("^fleeting") ~= nil
end

local CAULDRON_CHARGES = 40

-- Known placement spells. Matching by ID is precise; the name fallback below
-- catches future cauldrons we haven't ID'd yet.
local CAULDRON_SPELL_IDS = {
    [1240019] = "Prepare Midnight Flask Cauldron",
    [432878]  = "Prepare Algari Flask Cauldron",
}
local CAULDRON_ACTIVE_DURATION = 300  -- cauldron lasts 5 minutes after placement

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function RefreshUI()
    local f = _G["CauldronTrackerFrame"]
    if f and f:IsShown() and f.Refresh then f:Refresh() end
end

-- Dedicated frame for ADDON_LOADED
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("ADDON_LOADED")
loadFrame:SetScript("OnEvent", function(self, event, name)
    if name == addonName then
        CauldronTrackerDB = CauldronTrackerDB or {}
        self:UnregisterEvent("ADDON_LOADED")

        -- Restore a still-active cauldron window across /reload so stragglers'
        -- flasks keep counting (each placement stores its expiry as epoch time).
        local nowEpoch = time()
        for day, data in pairs(CauldronTrackerDB) do
            if type(data) == "table" and type(data.cauldrons) == "table" then
                for _, c in ipairs(data.cauldrons) do
                    if type(c) == "table" and c.expiresAt and c.expiresAt > nowEpoch then
                        cauldronActiveUntil = math.max(cauldronActiveUntil,
                            GetTime() + (c.expiresAt - nowEpoch))
                        activeDayKey = day
                    end
                end
            end
        end

        Print("Loaded. /cauldron to view, /cauldron reset to clear.")
    end
end)

-- A cauldron has 40 charges over 5 minutes. We track an "active window" — when a cauldron
-- is known to be active, any "Fleeting"-item create is counted as 1 cauldron use.
-- Outside the window, creates are buffered; if 3+ DIFFERENT players create within 30s,
-- we infer a cauldron is active (spell-cast detection missed) and retroactively count them.
-- (cauldronActiveUntil/activeDayKey are declared above with CurrentDayKey)
local recentCreates = {}  -- buffer of {time, player} for events not yet attributed to a cauldron
local recentCastGUIDs = {}  -- castGUID -> time, dedup spell-cast detections
local recentLootKeys = {}  -- (player|itemLink) -> time, dedup duplicate loot messages
local BURST_THRESHOLD = 3   -- distinct players required to infer a cauldron
local BURST_WINDOW = 30
local LOOT_DEDUP_WINDOW = 1.0

local function ActivateCauldron(now)
    if now >= cauldronActiveUntil then
        -- Fresh window: anchor all writes to the day it opened
        activeDayKey = Today()
    end
    cauldronActiveUntil = math.max(cauldronActiveUntil, now + CAULDRON_ACTIVE_DURATION)
end

-- Detect cauldron placement via UNIT_SPELLCAST_START (has cast time, unlike taking which is instant)
local clFrame = CreateFrame("Frame")
clFrame:RegisterEvent("UNIT_SPELLCAST_START")
clFrame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
    if not unit then return end
    local prefix = string.sub(unit, 1, 4)
    if prefix ~= "raid" and prefix ~= "part" and unit ~= "player" then return end
    -- IsSecret must run before any truthiness test: boolean-testing a secret
    -- value is itself an error under 12.0 semantics.
    if IsSecret(spellID) or not spellID then return end

    -- Match by known spell ID first; fall back to name-contains for unknown cauldrons
    local matched = CAULDRON_SPELL_IDS[spellID]
    if not matched then
        local spellName = C_Spell.GetSpellName(spellID)
        if IsSecret(spellName) or not spellName then return end
        if not string.find(string.lower(spellName), "cauldron") then return end
        matched = spellName
    end
    if IsSecret(castGUID) then castGUID = nil end
    DebugPrint(string.format("UNIT_SPELLCAST_START cauldron: unit=%s spellID=%s spell=%s castGUID=%s",
        tostring(unit), tostring(spellID), tostring(matched), tostring(castGUID)))

    -- Dedup: same cast can fire for both "player" and "raidN" when you're the caster
    if castGUID and recentCastGUIDs[castGUID] then return end
    if castGUID then recentCastGUIDs[castGUID] = GetTime() end

    local sourceName = UnitName(unit)
    if IsSecret(sourceName) then return end
    local placer = StripRealm(sourceName) or "?"
    local now = GetTime()
    ActivateCauldron(now)
    local cauldrons = GetTodayCauldrons()
    table.insert(cauldrons, { player = placer, time = date("%H:%M"),
        expiresAt = time() + CAULDRON_ACTIVE_DURATION })

    -- Any creates buffered just before the spell fired are part of this cauldron —
    -- count them, but only recent ones (the buffer is only trimmed when loot
    -- arrives, so it can still hold stale entries from many minutes ago).
    local counts = GetTodayCounts()
    for _, e in ipairs(recentCreates) do
        if now - e.time <= BURST_WINDOW then
            local prev = counts[e.player] or 0
            counts[e.player] = prev + 1
            DebugPrint(string.format("  retroactive +1 for %s on placement (was %d, now %d)",
                e.player, prev, counts[e.player]))
        else
            DebugPrint(string.format("  dropped stale buffered create from %s (%.0fs old)",
                e.player, now - e.time))
        end
    end
    recentCreates = {}

    Print(string.format("%s placed a cauldron! (%d total today)", placer, #cauldrons))
    RefreshUI()
end)

local function CountUniquePlayers(buffer)
    local seen, n = {}, 0
    for _, e in ipairs(buffer) do
        if not seen[e.player] then
            seen[e.player] = true
            n = n + 1
        end
    end
    return n
end

-- Dedicated frame for CHAT_MSG_LOOT (has 12.0 secret values for other players)
local lootFrame = CreateFrame("Frame")
lootFrame:RegisterEvent("CHAT_MSG_LOOT")
lootFrame:SetScript("OnEvent", function(self, event, msg, playerName)
    if IsSecret(msg) or not msg then
        DebugPrint(string.format("CHAT_MSG_LOOT skipped: msg=%s playerName=%s",
            IsSecret(msg) and "secret" or "nil",
            IsSecret(playerName) and "secret" or tostring(playerName)))
        return
    end
    DebugPrint(string.format("CHAT_MSG_LOOT raw msg=%q playerName=%s",
        msg, IsSecret(playerName) and "secret" or tostring(playerName)))
    local itemLink = string.match(msg, "|Hitem:.-%|h%[.-%]|h")
    if not itemLink then
        DebugPrint("  no item link found, skipping")
        return
    end
    if not IsFleetingItem(itemLink) then
        DebugPrint("  item is not Fleeting, skipping: " .. itemLink)
        return
    end

    -- Flask cauldrons hand out one item per charge (no stack). Personal alchemy crafts
    -- in stacks of 5+ ("x5"), so any x-quantity is bench crafting and should be ignored.
    local qty = tonumber(string.match(msg, "x(%d+)")) or 1
    if qty > 1 then
        DebugPrint(string.format("  skipping personal craft (qty=%d): %s", qty, itemLink))
        return
    end

    local player
    if not IsSecret(playerName) and playerName and playerName ~= "" then
        player = StripRealm(playerName)
        DebugPrint("  player from playerName arg: " .. player)
    else
        player = UnitName("player")
        DebugPrint("  player fallback to UnitName('player'): " .. tostring(player))
    end

    if not player or player == "" then
        DebugPrint("  no player resolved, skipping")
        return
    end

    -- Dedup: WoW can fire the same event twice (once as "You create", once as group broadcast).
    local now = GetTime()
    local lootKey = player .. "|" .. itemLink
    local lastSeen = recentLootKeys[lootKey]
    if lastSeen and (now - lastSeen) < LOOT_DEDUP_WINDOW then
        DebugPrint(string.format("  DEDUP HIT: same %s create %.2fs ago, skipping", player, now - lastSeen))
        return
    end
    recentLootKeys[lootKey] = now
    if math.random() < 0.05 then
        for k, t in pairs(recentLootKeys) do
            if now - t > LOOT_DEDUP_WINDOW then recentLootKeys[k] = nil end
        end
    end

    -- Each create == 1 charge consumed, regardless of stack size (1 charge = 1 flask OR 5 potions).
    if now < cauldronActiveUntil then
        local counts = GetTodayCounts()
        local prev = counts[player] or 0
        counts[player] = prev + 1
        DebugPrint(string.format("  counted +1 for %s (was %d, now %d) [active window]",
            player, prev, counts[player]))
        RefreshUI()
        return
    end

    -- No active cauldron — buffer and check for a burst that implies one is active.
    tinsert(recentCreates, { time = now, player = player })
    while #recentCreates > 0 and (now - recentCreates[1].time) > BURST_WINDOW do
        tremove(recentCreates, 1)
    end
    local uniqueN = CountUniquePlayers(recentCreates)
    DebugPrint(string.format("  buffered (no active cauldron, %d events from %d players in window)",
        #recentCreates, uniqueN))

    if uniqueN >= BURST_THRESHOLD then
        ActivateCauldron(now)
        local cauldrons = GetTodayCauldrons()
        table.insert(cauldrons, { player = "?", time = date("%H:%M"),
            expiresAt = time() + CAULDRON_ACTIVE_DURATION })
        local counts = GetTodayCounts()
        for _, e in ipairs(recentCreates) do
            local prev = counts[e.player] or 0
            counts[e.player] = prev + 1
            DebugPrint(string.format("  burst counted +1 for %s (was %d, now %d)",
                e.player, prev, counts[e.player]))
        end
        Print(string.format("Cauldron detected (burst of %d creates from %d players)! (%d total today)",
            #recentCreates, uniqueN, #cauldrons))
        recentCreates = {}
        RefreshUI()
    end
end)

local function ShowCounts(day)
    local data = CauldronTrackerDB[day]
    if not data or not next(data) then
        Print("No flasks/phials tracked for " .. day .. ".")
        return
    end
    -- Handle old format (flat player counts) and new format (counts + cauldrons)
    local counts = data.counts or data
    if not next(counts) then
        Print("No flasks/phials tracked for " .. day .. ".")
        return
    end

    local sorted = {}
    for name, count in pairs(counts) do
        if type(count) == "number" then
            table.insert(sorted, { name = name, count = count })
        end
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)

    local numCauldrons = data.cauldrons and #data.cauldrons or 0
    local allotment = 0
    if numCauldrons > 0 then
        local raidSize = GetNumGroupMembers()
        if raidSize == 0 then raidSize = 1 end
        allotment = math.floor(numCauldrons * CAULDRON_CHARGES / raidSize)
        Print(string.format("--- %s (%d cauldrons, %d per person) ---", day, numCauldrons, allotment))
    else
        Print("--- " .. day .. " ---")
    end
    for _, entry in ipairs(sorted) do
        local color
        if allotment > 0 and entry.count > allotment then
            color = "|cffff5555"
        else
            color = "|cff00ff00"
        end
        Print(string.format("  %s%s|r: %d", color, entry.name, entry.count))
    end
end

SLASH_CAULDRON1 = "/cauldron"
SLASH_CAULDRON2 = "/ct"
SlashCmdList["CAULDRON"] = function(msg)
    local trimmed = strtrim(msg)
    local cmd = trimmed:lower()
    if cmd == "clearlog" then
        CauldronTrackerDB.debugLog = {}
        Print("Log cleared.")
    elseif cmd == "reset" then
        CauldronTrackerDB[CurrentDayKey()] = {}
        Print("Today's counts reset.")
    elseif cmd == "all" then
        local days = {}
        for day in pairs(CauldronTrackerDB) do
            -- Only real day tables (skips debugLog and any future non-day keys)
            if day:match("^%d%d%d%d%-%d%d%-%d%d$") then
                table.insert(days, day)
            end
        end
        table.sort(days)
        if #days == 0 then
            Print("No data.")
            return
        end
        for _, day in ipairs(days) do
            ShowCounts(day)
        end
    elseif cmd:sub(1, 3) == "add" then
        local who = strtrim(trimmed:sub(4))
        if who == "" then who = UnitName("player") end
        local cauldrons = GetTodayCauldrons()
        table.insert(cauldrons, { player = who, time = date("%H:%M") })
        Print(string.format("Recorded cauldron from %s (%d total today)", who, #cauldrons))
        RefreshUI()
    elseif cmd == "share" then
        local counts = GetTodayCounts()
        if not next(counts) then
            Print("Nothing to share.")
            return
        end
        local sorted = {}
        for name, count in pairs(counts) do
            table.insert(sorted, { name = name, count = count })
        end
        table.sort(sorted, function(a, b) return a.count > b.count end)
        local channel = IsInRaid() and "RAID" or IsInGroup() and "PARTY" or nil
        if channel then
            C_ChatInfo.SendChatMessage("[Cauldron] Flask/Phial counts:", channel)
            for _, entry in ipairs(sorted) do
                C_ChatInfo.SendChatMessage(string.format("  %s: %d", entry.name, entry.count), channel)
            end
        else
            Print("Not in a group.")
        end
    else
        ShowCounts(CurrentDayKey())
    end
end
