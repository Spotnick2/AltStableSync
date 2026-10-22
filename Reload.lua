------------------------------------------------------------
-- Reload.lua - "Reload to finish" (#10)
--
-- Action bar visibility is written and reads back at once, but the bars
-- only appear after a reload (measured on the beta, 2026-10-22). ReloadUI()
-- is protected (References\Docs\PORTING-TBC-TO-FOREVER.md), so the button is
-- a SecureActionButtonTemplate whose macro is /reload, registered for both
-- mouse edges (the client acts on one of them, porting guide): the player's
-- click runs the slash command. Nothing ever reloads by itself.
--
-- The secure button is built at load (a protected frame can't be created
-- in combat) and parented to UIParent, placed by coordinates beside our
-- prompt, never anchored to it: anchoring would make our prompt protected
-- too. Both are hidden when combat starts (PLAYER_REGEN_DISABLED, the last
-- moment a protected frame can still be hidden), and the prompt opens only
-- out of combat.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Reload = {}
ASS.Reload = Reload

-- The prompt sits at CENTER (0, 120), 380 x 130, and doesn't move; the
-- button's centre is where the prompt's bottom-right button slot is.
local W, H, X, Y = 380, 130, 0, 120
local BUTTON_X, BUTTON_Y = X + W / 2 - 140 - 60, Y - H / 2 + 16 + 12

local prompt, button

local function Build()
    local f = CreateFrame("Frame", "AltStableSyncReload", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", X, Y)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    ASS.Preview.Glass(f)
    tinsert(UISpecialFrames, "AltStableSyncReload")
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 20, -18)
    f.title:SetText("Reload to finish")
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", 20, -46)
    f.body:SetWidth(W - 40)
    f.body:SetJustifyH("LEFT")
    local later = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    later:SetSize(110, 24)
    later:SetPoint("BOTTOMRIGHT", -20, 16)
    later:SetText("Later")
    later:SetScript("OnClick", function() f:Hide() end)
    f.later = later

    -- The secure template last, so its click handler is the one that stays
    -- (a later template's scripts replace an earlier one's).
    local b = CreateFrame("Button", "AltStableSyncReloadButton", UIParent,
                          "UIPanelButtonTemplate,SecureActionButtonTemplate")
    b:SetSize(120, 24)
    b:SetPoint("CENTER", UIParent, "CENTER", BUTTON_X, BUTTON_Y)
    b:SetFrameStrata("DIALOG")
    -- Above the prompt, which takes the mouse: on the beta (2026-10-22) a
    -- click on the button did nothing, most likely landing on the prompt.
    b:SetFrameLevel(f:GetFrameLevel() + 10)
    b:SetText("Reload now")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "/reload")
    b:Hide()

    -- Out of combat only: Escape or Later hide the prompt, and the button
    -- with it. In combat the button was already hidden at combat start.
    f:SetScript("OnHide", function()
        if not InCombatLockdown() then b:Hide() end
    end)
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function()
        b:Hide()
        f:Hide()
    end)
    f:Hide()
    return f, b
end
prompt, button = Build()

-- Ask for a reload, out of combat only. Returns true when the prompt opened.
function Reload.Ask(text)
    if InCombatLockdown() then return false end
    prompt.body:SetText(text)
    prompt:Show()
    button:SetFrameLevel(prompt:GetFrameLevel() + 10)
    button:Show()
    return true
end

function Reload.Shown() return prompt:IsShown() end

Reload._test = { prompt = prompt, button = button }
