local addonName = ...

local CTFrame
local FRAME_WIDTH = 280
local FRAME_HEIGHT = 300
local ROW_HEIGHT = 20
local HEADER_HEIGHT = 24
local PADDING = 8

local function ApplyBackdrop(f, br, bg, bb, ba, er, eg, eb, ea)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(br, bg, bb, ba)
    f:SetBackdropBorderColor(er, eg, eb, ea)
end

local function Today()
    return date("%Y-%m-%d")
end

local function CreateMainFrame()
    local f = CreateFrame("Frame", "CauldronTrackerFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    ApplyBackdrop(f, 0.08, 0.08, 0.08, 0.95, 0.3, 0.3, 0.3, 1)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
    title:SetPoint("RIGHT", f, "RIGHT", -30, 0)
    title:SetJustifyH("LEFT")
    title:SetText("Cauldron Tracker")
    title:SetTextColor(1, 0.84, 0)
    f.titleText = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    tinsert(UISpecialFrames, "CauldronTrackerFrame")

    -- Scroll area
    local scrollFrame = CreateFrame("ScrollFrame", "CauldronTrackerScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -32)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, PADDING)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(FRAME_WIDTH - PADDING * 2 - 26)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    -- Hide scrollbar when content fits
    local scrollBar = scrollFrame.ScrollBar or _G["CauldronTrackerScrollScrollBar"]
    if scrollBar then
        hooksecurefunc(scrollChild, "SetHeight", function(self, h)
            local viewHeight = scrollFrame:GetHeight()
            if h <= viewHeight then
                scrollBar:Hide()
                scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING, PADDING)
            else
                scrollBar:Show()
                scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, PADDING)
            end
        end)
    end

    f.scrollFrame = scrollFrame
    f.scrollChild = scrollChild

    return f
end

local function ClearContent(parent)
    for _, child in ipairs({ parent.scrollChild:GetRegions() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, child in ipairs({ parent.scrollChild:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
end

local function Refresh(f)
    ClearContent(f)
    local sc = f.scrollChild
    local contentWidth = sc:GetWidth()
    local y = 0

    local today = Today()
    local data = CauldronTrackerDB and CauldronTrackerDB[today]

    -- Handle old format (flat counts) and new format (counts + cauldrons)
    local counts, cauldrons
    if data and data.counts then
        counts = data.counts
        cauldrons = data.cauldrons or {}
    else
        counts = data
        cauldrons = {}
    end

    local numCauldrons = #cauldrons
    local allotment = 0
    if numCauldrons > 0 then
        local raidSize = GetNumGroupMembers()
        if raidSize == 0 then raidSize = 1 end
        allotment = math.floor(numCauldrons * 40 / raidSize)
        local label = numCauldrons == 1 and "cauldron" or "cauldrons"
        f.titleText:SetText(string.format("Cauldron — %d each (%d %s)", allotment, numCauldrons, label))
    else
        f.titleText:SetText("Cauldron — " .. today)
    end

    if not counts or not next(counts) then
        local empty = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", sc, "TOPLEFT", 6, -(y + 20))
        empty:SetText("No flasks/phials tracked today.")
        empty:SetTextColor(0.5, 0.5, 0.5)
        sc:SetHeight(60)
        return
    end

    local sorted = {}
    for name, count in pairs(counts) do
        table.insert(sorted, { name = name, count = count })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)

    -- Header
    local headerBg = sc:CreateTexture(nil, "BACKGROUND")
    headerBg:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -y)
    headerBg:SetSize(contentWidth, HEADER_HEIGHT)
    headerBg:SetColorTexture(0.2, 0.2, 0.2, 0.5)

    local nameHeader = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameHeader:SetPoint("LEFT", sc, "TOPLEFT", 8, -(y + HEADER_HEIGHT / 2))
    nameHeader:SetText("Player")
    nameHeader:SetTextColor(0.7, 0.7, 0.7)

    local countHeader = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countHeader:SetPoint("RIGHT", sc, "TOPRIGHT", -8, -(y + HEADER_HEIGHT / 2))
    countHeader:SetText("Count")
    countHeader:SetTextColor(0.7, 0.7, 0.7)

    y = y + HEADER_HEIGHT

    for i, entry in ipairs(sorted) do
        if i % 2 == 0 then
            local rowBg = sc:CreateTexture(nil, "BACKGROUND")
            rowBg:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -y)
            rowBg:SetSize(contentWidth, ROW_HEIGHT)
            rowBg:SetColorTexture(0.15, 0.15, 0.15, 0.4)
        end

        local cr, cg, cb = 0, 1, 0
        if allotment > 0 and entry.count > allotment then
            cr, cg, cb = 1, 0.33, 0.33
        elseif allotment == 0 and entry.count > 1 then
            cr, cg, cb = 1, 0.33, 0.33
        end

        local nameFs = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameFs:SetPoint("LEFT", sc, "TOPLEFT", 8, -(y + ROW_HEIGHT / 2))
        nameFs:SetText(entry.name)
        nameFs:SetTextColor(cr, cg, cb)

        local countFs = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        countFs:SetPoint("RIGHT", sc, "TOPRIGHT", -8, -(y + ROW_HEIGHT / 2))
        countFs:SetText(tostring(entry.count))
        countFs:SetTextColor(cr, cg, cb)

        y = y + ROW_HEIGHT
    end

    -- Total
    y = y + 4
    local totalFs = sc:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    totalFs:SetPoint("LEFT", sc, "TOPLEFT", 8, -(y + ROW_HEIGHT / 2))
    local total = 0
    for _, e in ipairs(sorted) do total = total + e.count end
    totalFs:SetText(string.format("Total: %d flasks, %d players", total, #sorted))
    totalFs:SetTextColor(0.7, 0.7, 0.7)
    y = y + ROW_HEIGHT

    sc:SetHeight(math.max(y, 1))
    f.scrollFrame:SetVerticalScroll(0)
end

local function ToggleUI()
    if not CTFrame then
        CTFrame = CreateMainFrame()
        CTFrame.Refresh = function(self) Refresh(self) end
    end
    if CTFrame:IsShown() then
        CTFrame:Hide()
    else
        Refresh(CTFrame)
        CTFrame:Show()
    end
end

-- Hook into the slash command — override after core loads
local origHandler = SlashCmdList["CAULDRON"]
SlashCmdList["CAULDRON"] = function(msg)
    local trimmed = strtrim(msg):lower()
    if trimmed == "" or trimmed == "ui" then
        ToggleUI()
        return
    end
    if origHandler then
        origHandler(msg)
    end
    -- Refresh UI if open
    if CTFrame and CTFrame:IsShown() then
        Refresh(CTFrame)
    end
end
