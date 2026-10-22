------------------------------------------------------------
-- Preview.lua - our own confirmation frame (never a StaticPopup: it taints
-- Blizzard's dialog pool, measured 70205)
--
-- Preview.Show{ title, lines, confirm = "Load", onConfirm = fn, onCancel = fn,
--               cancel = "Cancel", onCancelButton = fn,
--               check = { text, checked, onToggle = fn(checked) } }
-- `check`: one optional tick box ("Include character macros", #6). Ticking
-- it writes nothing: onToggle shows a new preview of the changed plan.
-- One frame, reused; parented to UIParent; Escape and Cancel close it without
-- writing anything. onConfirm runs at most once per Show.
-- Preview.Shown() is the options table on screen now, or nil.
-- The panel (#9) opens these same previews; it never writes by itself.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Preview = {}
ASS.Preview = Preview

local frame
local current

-- The LibGlass "large" look, or the dialog backdrop without LibGlass. The
-- panel (#9) uses it too.
function Preview.Glass(f)
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
end

-- Called whenever the preview shows or hides (the panel's Escape handling).
Preview.onVisibility = nil
local function Visibility()
    if Preview.onVisibility then pcall(Preview.onVisibility) end
end

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
    Preview.Glass(f)
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
    local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("BOTTOMLEFT", 16, 16)
    check.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    check:SetScript("OnClick", function(self)
        local c = current and current.check
        if c and c.onToggle then c.onToggle(self:GetChecked() and true or false) end
    end)
    f.check = check
    f:SetScript("OnHide", function(self)
        current = nil
        local cb = self.onCancel
        self.onConfirm, self.onCancel = nil, nil
        if cb then cb() end
        Visibility()
    end)
    f:SetScript("OnShow", Visibility)
    -- `onCancelButton` runs only for a click on this button: Escape and any
    -- other hide run `onCancel` alone (the first-login offer's "Not now", #10).
    f.cancel:SetScript("OnClick", function()
        local cb = current and current.onCancelButton
        f:Hide()
        if cb then cb() end
    end)
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
    -- Shown literally (#75), into new strings: `opts` is shown again as it
    -- is (the waiting preview), so it is never changed.
    local L = ASS.Literal
    frame.title:SetText(L(opts.title or "AltStableSync"))
    local shown = {}
    for i, line in ipairs(opts.lines or {}) do shown[i] = L(line) end
    frame.body:SetText(table.concat(shown, "\n"))
    frame.content:SetHeight(math.max(10, frame.body:GetStringHeight() + 8))
    frame.scroll:SetVerticalScroll(0)
    frame.confirm:SetText(opts.confirm or "Load")
    frame.cancel:SetText(opts.cancel or "Cancel")
    -- A longer label ("Preview and apply") widens its button to fit.
    local fs = frame.confirm.GetFontString and frame.confirm:GetFontString()
    local tw = fs and fs.GetStringWidth and fs:GetStringWidth()
    frame.confirm:SetWidth(math.max(110, (type(tw) == "number" and tw or 0) + 24))
    if opts.confirm == false then frame.confirm:Hide() else frame.confirm:Show() end
    frame.onConfirm, frame.onCancel = opts.onConfirm, opts.onCancel
    if opts.check then
        frame.check.label:SetText(opts.check.text or "")
        frame.check:SetChecked(opts.check.checked and true or false)
        frame.check:Show()
        frame.check.label:Show()
    else
        frame.check:Hide()
        frame.check.label:Hide()
    end
    frame:Show()
    current = opts
    -- Said here too: the frame is created shown, so its first Show() fires
    -- no OnShow.
    Visibility()
end

function Preview.Shown() return current end

function Preview.Hide()
    if frame then frame:Hide() end
end
