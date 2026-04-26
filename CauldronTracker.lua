local addonName = ...

local function Today()
    return date("%Y-%m-%d")
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[Cauldron]|r " .. msg)
end

local function StripRealm(name)
    if not name then return name end
    return (strsplit("-", name, 2))
end

local function GetTodayData()
    local today = Today()
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

-- Match flask/phial items from loot messages
local function IsFlaskOrPhial(itemLink)
    if not itemLink then return false end
    local name = C_Item.GetItemNameByID(itemLink) or GetItemInfo(itemLink)
    if not name then
        name = itemLink:match("%[(.-)%]")
    end
    if not name then return false end
    name = name:lower()
    return name:find("flask") or name:find("phial")
end

local CAULDRON_CHARGES = 40

local function GetAllotment()
    local cauldrons = GetTodayCauldrons()
    local totalCharges = #cauldrons * CAULDRON_CHARGES
    local raidSize = GetNumGroupMembers()
    if raidSize == 0 then raidSize = 1 end
    return math.floor(totalCharges / raidSize)
end

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
        Print("Loaded. /cauldron to view, /cauldron reset to clear.")
    end
end)

-- Burst detection state (declared early so spell-cast handler can update it)
local recentLoots = {}  -- timestamps of recent flask loots
local lastFlaskLootTime = 0  -- timestamp of most recent flask loot (or spell-cast detection)
local burstFiredThisSession = false  -- has burst already counted a cauldron in the current loot session?
local recentCastGUIDs = {}  -- castGUID -> time, dedup spell-cast detections
local BURST_THRESHOLD = 3
local BURST_WINDOW = 30
local SESSION_QUIET = 60  -- seconds of no flask loots before considering a new cauldron session has started

-- Detect cauldron placement via UNIT_SPELLCAST_START (has cast time, unlike taking which is instant)
local clFrame = CreateFrame("Frame")
clFrame:RegisterEvent("UNIT_SPELLCAST_START")
clFrame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
    if not unit then return end
    local prefix = string.sub(unit, 1, 4)
    if prefix ~= "raid" and prefix ~= "part" and unit ~= "player" then return end
    local spellName = C_Spell.GetSpellName(spellID)
    if not spellName then return end
    if IsSecret(spellName) then return end
    if not string.find(string.lower(spellName), "cauldron") then return end

    -- Dedup: same cast can fire for both "player" and "raidN" when you're the caster
    if castGUID and recentCastGUIDs[castGUID] then return end
    if castGUID then recentCastGUIDs[castGUID] = GetTime() end

    local sourceName = UnitName(unit)
    if IsSecret(sourceName) then return end
    local placer = StripRealm(sourceName)
    local cauldrons = GetTodayCauldrons()
    table.insert(cauldrons, { player = placer, time = date("%H:%M") })

    -- Mark the loot session as already-counted so the upcoming flood of flask loots doesn't add a duplicate
    burstFiredThisSession = true
    lastFlaskLootTime = GetTime()

    Print(string.format("%s placed a cauldron! (%d total today)", placer, #cauldrons))
    RefreshUI()
end)

local function CheckForCauldronBurst()
    local now = GetTime()
    -- Prune old entries
    local fresh = {}
    for _, t in ipairs(recentLoots) do
        if now - t < BURST_WINDOW then
            tinsert(fresh, t)
        end
    end
    recentLoots = fresh

    if #recentLoots >= BURST_THRESHOLD and not burstFiredThisSession then
        burstFiredThisSession = true
        local cauldrons = GetTodayCauldrons()
        table.insert(cauldrons, { player = "?", time = date("%H:%M") })
        Print(string.format("Cauldron detected (burst of %d loots)! (%d total today)", #recentLoots, #cauldrons))
        RefreshUI()
    end
end

-- Dedicated frame for CHAT_MSG_LOOT (has 12.0 secret values for other players)
local lootFrame = CreateFrame("Frame")
lootFrame:RegisterEvent("CHAT_MSG_LOOT")
lootFrame:SetScript("OnEvent", function(self, event, msg, playerName)
    if not msg or IsSecret(msg) then return end
    local itemLink = string.match(msg, "|Hitem:.-%|h%[.-%]|h")
    if not itemLink then return end
    if not IsFlaskOrPhial(itemLink) then return end

    local player
    if playerName and not IsSecret(playerName) and playerName ~= "" then
        player = StripRealm(playerName)
    else
        player = UnitName("player")
    end

    if not player or player == "" then return end

    local qty = tonumber(string.match(msg, "x(%d+)")) or 1
    local counts = GetTodayCounts()
    counts[player] = (counts[player] or 0) + qty

    -- Track for burst detection. A long quiet period since the last flask loot resets the session,
    -- allowing burst detection to fire again for a new cauldron.
    local now = GetTime()
    if now - lastFlaskLootTime > SESSION_QUIET then
        burstFiredThisSession = false
    end
    lastFlaskLootTime = now
    tinsert(recentLoots, now)
    CheckForCauldronBurst()

    RefreshUI()
end)

local function ShowCounts(day)
    local counts = CauldronTrackerDB[day]
    if not counts or not next(counts) then
        Print("No flasks/phials tracked for " .. day .. ".")
        return
    end

    local sorted = {}
    for name, count in pairs(counts) do
        table.insert(sorted, { name = name, count = count })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)

    local data = CauldronTrackerDB[day]
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
    msg = strtrim(msg):lower()
    if msg == "reset" then
        CauldronTrackerDB[Today()] = {}
        Print("Today's counts reset.")
    elseif msg == "all" then
        local days = {}
        for day in pairs(CauldronTrackerDB) do
            table.insert(days, day)
        end
        table.sort(days)
        if #days == 0 then
            Print("No data.")
            return
        end
        for _, day in ipairs(days) do
            ShowCounts(day)
        end
    elseif msg:sub(1, 3) == "add" then
        local who = strtrim(msg:sub(4))
        if who == "" then who = UnitName("player") end
        local cauldrons = GetTodayCauldrons()
        table.insert(cauldrons, { player = who, time = date("%H:%M") })
        Print(string.format("Recorded cauldron from %s (%d total today)", who, #cauldrons))
        RefreshUI()
    elseif msg == "share" then
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
            SendChatMessage("[Cauldron] Flask/Phial counts:", channel)
            for _, entry in ipairs(sorted) do
                SendChatMessage(string.format("  %s: %d", entry.name, entry.count), channel)
            end
        else
            Print("Not in a group.")
        end
    else
        ShowCounts(Today())
    end
end
