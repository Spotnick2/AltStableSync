------------------------------------------------------------
-- Minimap.lua - the minimap button, the addon-list entry and the key binding (#62)
--
-- Each only opens the window: none writes game state or the catalog. The
-- button's own position and visibility are the only things saved
-- (AltStableSyncDB.minimap = { angle, hide }, schema 9), read and written
-- through ASS.db only, so refused SavedVariables are never touched.
--
-- The button is AltStable's own (..\AltStable\SheetUI.lua, "Minimap button"):
-- no LibDBIcon, an angle around the minimap's edge on an ellipse measured
-- from the live frame, and a two-layer icon so a file id that stops
-- resolving shows the underlay instead of nothing. The addon list (the
-- minimap's addon compartment) and Bindings.xml follow GuildSpy (#5 there).
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local MinimapButton = {}      -- not "Minimap": that is the client's minimap frame
ASS.MinimapButton = MinimapButton

local ICON = 8197123                                   -- the TOC's IconTexture
local ICON_UNDERLAY = "Interface\\Icons\\INV_Misc_GroupNeedMore"
local DEFAULT_ANGLE = 200
-- AltStable's measured values: the button centre sits 10 units past the
-- minimap's edge; 99 is half the 198-unit Minimap (build 69913), used only
-- when the frame reports no size yet.
local CLEARANCE, FALLBACK_RADIUS = 10, 99

local btn

local function Settings() return ASS.db and ASS.db.minimap end
local function Angle()
    local s = Settings()
    return s and tonumber(s.angle) or DEFAULT_ANGLE
end
local function Hidden()
    local s = Settings()
    return s ~= nil and s.hide == true
end
-- The first write makes the table; refused or uninitialised data is never written.
local function Save(field, value)
    if not ASS.db then return end
    ASS.db.minimap = ASS.db.minimap or {}
    ASS.db.minimap[field] = value
end

function MinimapButton.Position()
    if not (btn and Minimap) then return end
    local rads = math.rad(Angle())
    local w, h = Minimap:GetWidth() or 0, Minimap:GetHeight() or 0
    local rx = (w > 0 and w / 2 or FALLBACK_RADIUS) + CLEARANCE
    local ry = (h > 0 and h / 2 or FALLBACK_RADIUS) + CLEARANCE
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", rx * math.cos(rads), ry * math.sin(rads))
end

-- One click, from the button or the addon list (both pass something first,
-- the button or the addon's name, then the mouse button).
function MinimapButton.Click(_, button)
    local Panel = ASS.Panel
    if not Panel then return end
    if button == "RightButton" then Panel.Open("backups") else Panel.Toggle() end
end

-- The tooltip: the save target and the other account's availability (the
-- panel's own read-only model and wording), then what the clicks do.
local HINT = { 0.75, 0.78, 0.85 }
function MinimapButton.Tooltip(tip, drag)
    tip:AddLine("AltStableSync")
    local ok, m = pcall(function() return ASS.Panel and ASS.Panel.Model({}) end)
    if ok and type(m) == "table" then
        if m.blocked then
            tip:AddLine(m.blocked, 1, 0.5, 0.3, true)
        else
            local t = m.target
            if not t then
                tip:AddLine("No save target yet", 0.8, 0.8, 0.8)
            elseif t.deleted then
                tip:AddLine("Save target: " .. tostring(t.name or "?") .. " (removed)", 1, 1, 1)
            else
                tip:AddLine(("Save target: %s - %s"):format(t.name, tostring(t.category)), 1, 1, 1)
            end
            if m.link then
                if m.online then tip:AddLine(m.link, 0.3, 0.9, 0.4) else tip:AddLine(m.link, 0.7, 0.7, 0.7) end
            end
        end
    end
    tip:AddLine("Left-click: open or close the window", HINT[1], HINT[2], HINT[3])
    tip:AddLine("Right-click: backups", HINT[1], HINT[2], HINT[3])
    if drag then tip:AddLine("Drag: move around the minimap", HINT[1], HINT[2], HINT[3]) end
end

local function Create()
    if btn or not Minimap then return end
    local b = CreateFrame("Button", "AltStableSyncMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    -- The underlay shows only if the file id above it stops resolving.
    local under = b:CreateTexture(nil, "BACKGROUND")
    under:SetTexture(ICON_UNDERLAY)
    under:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    for _, t in ipairs({ icon, under }) do
        t:SetSize(20, 20)
        t:SetPoint("CENTER", b, "CENTER", 0, 1)
    end
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    local highlight = b:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)

    b:SetScript("OnDragStart", function(self)
        self.isDragging = true
        if GameTooltip then GameTooltip:Hide() end
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            if not mx then return end
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            if not (px and scale and scale > 0) then return end
            px, py = px / scale, py / scale
            Save("angle", math.deg(math.atan2(py - my, px - mx)))
            MinimapButton.Position()
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self.isDragging = nil
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", MinimapButton.Click)
    b:SetScript("OnEnter", function(self)
        if self.isDragging or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        MinimapButton.Tooltip(GameTooltip, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    btn = b
    MinimapButton.Position()
    -- Follow the minimap if it's resized (UI scale, a reskin): a hook, never
    -- a SetScript on the client's frame. Recorded rather than swallowed.
    if type(Minimap.HookScript) == "function" then
        b._followsResize = pcall(Minimap.HookScript, Minimap, "OnSizeChanged", MinimapButton.Position)
    else
        b._followsResize = false
    end
    if Hidden() then b:Hide() end
end

function MinimapButton.Shown() return not Hidden() end

-- Show or hide it, and save that (only into usable data).
function MinimapButton.SetShown(on)
    Save("hide", (not on) or nil)
    if btn then if on then btn:Show() else btn:Hide() end end
end

-- /altsync minimap. The slash handler refuses it first on refused data.
if ASS.Commands then
    ASS.Commands.minimap = function()
        local on = not MinimapButton.Shown()
        MinimapButton.SetShown(on)
        ASS.Print(on and "Minimap button shown." or "Minimap button hidden: /altsync minimap shows it again. "
            .. "AltStableSync is still in the minimap's addon list.")
    end
end

-- Made once the UI is up; even on refused data, so the window can say why.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    Create()
end)

-- The TOC's AddonCompartmentFunc*: globals of our own name, which the
-- client's addon list looks up (it passes the addon's name, then the button).
AltStableSync_OnAddonCompartmentClick = MinimapButton.Click
function AltStableSync_OnAddonCompartmentEnter(_, row)
    if not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    MinimapButton.Tooltip(GameTooltip, false)
    GameTooltip:Show()
end
function AltStableSync_OnAddonCompartmentLeave() if GameTooltip then GameTooltip:Hide() end end

-- The key binding's line in Key Bindings > AltStableSync (Bindings.xml).
BINDING_NAME_ALTSTABLESYNC_TOGGLE = "Open or close AltStableSync"

MinimapButton._Button = function() return btn end
