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
    local f = CreateFrame("Frame", "AltStableSyncPreview", UIParent, "BackdropTemplate")
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
    -- The body scrolls: a full slice plan (12 slots, keys, skips) is longer
    -- than the frame, and every line must be reachable before confirming.
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 20, -50)
    scroll:SetPoint("BOTTOMRIGHT", -20, 52)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(410, 10)
    scroll:SetScrollChild(content)
    f.body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT")
    f.body:SetWidth(410)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.content, f.scroll = content, scroll
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = self:GetVerticalScrollRange()
        local v = math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40))
        self:SetVerticalScroll(v)
    end)
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
    frame.content:SetHeight(math.max(10, frame.body:GetStringHeight() + 8))
    frame.scroll:SetVerticalScroll(0)
    frame.confirm:SetText(opts.confirm or "Load")
    if opts.confirm == false then frame.confirm:Hide() else frame.confirm:Show() end
    frame.onConfirm, frame.onCancel = opts.onConfirm, opts.onCancel
    frame:Show()
end

function Preview.Hide()
    if frame then frame:Hide() end
end
