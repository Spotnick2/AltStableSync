------------------------------------------------------------
-- Preview.lua - our own confirmation frame (never a StaticPopup: it taints
-- Blizzard's dialog pool, measured 70205)
--
-- Preview.Show{ title, lines, confirm = "Load", onConfirm = fn, onCancel = fn }
-- One frame, reused; parented to UIParent; Escape and Cancel close it without
-- writing anything. onConfirm runs at most once per Show.
-- #9 replaces this with the two-tab panel; the contract stays.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Preview = {}
ASS.Preview = Preview

local frame

local function Build()
    local ok, f = pcall(CreateFrame, "Frame", "AltStableSyncPreview", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "AltStableSyncPreview", UIParent) end
    f:SetSize(460, 320)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local Glass = LibStub and LibStub("LibGlass-1.0", true)
    if Glass and Glass.New then
        local okG, inst = pcall(Glass.New, Glass)
        if okG and inst and inst.Apply then pcall(inst.Apply, f, "large") end
    elseif f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                        tile = true, tileSize = 32, edgeSize = 32,
                        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    end
    tinsert(UISpecialFrames, "AltStableSyncPreview")
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 20, -18)
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", 20, -50)
    f.body:SetPoint("BOTTOMRIGHT", -20, 52)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    local function button(text, x)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(110, 24)
        b:SetPoint("BOTTOMRIGHT", x, 16)
        b:SetText(text)
        return b
    end
    f.cancel = button("Cancel", -20)
    f.confirm = button("Load", -140)
    f:SetScript("OnHide", function(self)
        local cb = self.onCancel
        self.onConfirm, self.onCancel = nil, nil
        if cb then cb() end
    end)
    f.cancel:SetScript("OnClick", function() f:Hide() end)
    f.confirm:SetScript("OnClick", function()
        local cb = f.onConfirm
        f.onConfirm, f.onCancel = nil, nil
        f:Hide()
        if cb then cb() end
    end)
    return f
end

function Preview.Show(opts)
    frame = frame or Build()
    frame.title:SetText(opts.title or "AltStableSync")
    frame.body:SetText(table.concat(opts.lines or {}, "\n"))
    frame.confirm:SetText(opts.confirm or "Load")
    if opts.confirm == false then frame.confirm:Hide() else frame.confirm:Show() end
    frame.onConfirm, frame.onCancel = opts.onConfirm, opts.onCancel
    frame:Show()
end

function Preview.Hide()
    if frame then frame:Hide() end
end
