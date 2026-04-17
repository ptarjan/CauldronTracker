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

-- Dedicated frame for COMBAT_LOG_EVENT_UNFILTERED (isolated to avoid cross-event taint)
local clFrame = CreateFrame("Frame")
clFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
clFrame:SetScript("OnEvent", function()
    local _, subevent, _, _, sourceName, _, _, _, _, _, _, spellID, spellName = CombatLogGetCurrentEventInfo()
    if IsSecret(subevent) or IsSecret(sourceName) or IsSecret(spellName) then return end
    if subevent == "SPELL_CREATE" and spellName and string.find(string.lower(spellName), "cauldron") then
        local cauldrons = GetTodayCauldrons()
        local placer = StripRealm(sourceName)
        table.insert(cauldrons, { player = placer, time = date("%H:%M") })
        Print(string.format("%s placed a cauldron! (%d total today)", placer, #cauldrons))
        RefreshUI()
    end
end)

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
