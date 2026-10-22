------------------------------------------------------------
-- test_uisetup_panel.lua - the panel's UI setup tab (#10): a view and a
-- launcher. Its buttons open the /altsync ui previews; only their confirm
-- writes (the real Panel, Commands and Preview handlers).
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")

local G, UI = WoW.game, WoW.ui
local A, P, W

local function boot(ui)
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "UISetup.lua", "Preview.lua", "Reload.lua", "Commands.lua", "Panel.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    P, W = A.Panel, A.Panel._W
    G.setup{ class = "MAGE", guid = "Player-70-NEW", spells = { { id = 133, name = "Fireball" } } }
    UI.setup(ui)
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local function previewFrame() return _G.AltStableSyncPreview end
local function lines() local s = A.Preview.Shown(); return table.concat(s and s.lines or {}, "\n") end

-- No UI setup yet: the honest empty state (A32); Apply and Save off, Save As on.
do
    boot()
    P.Open("ui")
    check("empty: says what Save As does", W.uiContents:GetText():find("Save this character's layout", 1, true) ~= nil)
    check("empty: Apply off", not W.uiApply:IsEnabled())
    check("empty: Save off", not W.uiSave:IsEnabled())
    check("empty: Save As on", W.uiSaveAs:IsEnabled())
    -- Save As through the dialog: the preview first, then the entry.
    W.uiSaveAs:Click()
    local d = P._Dialog()
    d.name:SetText("Base")
    d.review:Click()
    check("save as: preview opened", lines():find('A new UI setup "Base"', 1, true) ~= nil)
    eq("save as: nothing saved before the confirm", #A.Catalog.ListAll("ui"), 0)
    previewFrame().confirm:Click()
    eq("save as: saved", #A.Catalog.ListAll("ui"), 1)
    P.Refresh()
    eq("save as: picker shows it", W.uiEntry.label:GetText(), "Base")
    check("save as: contents listed", W.uiContents:GetText():find("Layout:", 1, true) ~= nil)
    check("save as: Save on (this character's target)", W.uiSave:IsEnabled())
end

-- Apply from the tab opens the preview; nothing is written until its confirm.
do
    boot()
    A.Catalog.Create("ui", { name = "Base" }, { bars = { [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = false, [7] = false, [8] = false } })
    P.Open("ui")
    check("apply: on", W.uiApply:IsEnabled())
    W.uiApply:Click()
    check("apply: preview", lines():find("Action Bar 2: show", 1, true) ~= nil)
    eq("apply: no write before confirm", #UI.calls, 0)
    previewFrame().confirm:Click()
    check("apply: written on confirm", UI.bars[1] == true)
    UI.editMode = true
    P.Refresh()
    check("edit mode: Apply off", not W.uiApply:IsEnabled())
end

-- #91 review: bars written by an apply only show after a reload, so the
-- report opens "Reload to finish" with a secure /reload button. It never
-- reloads by itself, and it never opens or stays open in combat.
do
    boot()
    local R = A.Reload._test
    local b = R.button
    check("reload: a secure action button", tostring(b.template):find("SecureActionButtonTemplate", 1, true) ~= nil)
    eq("reload: macro type", b:GetAttribute("type"), "macro")
    eq("reload: runs /reload", b:GetAttribute("macrotext"), "/reload")
    check("reload: both mouse edges", b.clicks and b.clicks[1] == "AnyUp" and b.clicks[2] == "AnyDown")
    check("reload: parented to UIParent, not to the prompt", b.parent == UIParent)
    for _, p in ipairs(b.points or {}) do
        check("reload: placed against UIParent only", p[2] == UIParent)
    end
    check("reload: hidden at load", not R.prompt:IsShown() and not b:IsShown())

    A.Catalog.Create("ui", { name = "Bars" }, { bars = { [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = false, [7] = false, [8] = false } })
    P.Open("ui")
    W.uiApply:Click()
    check("reload: the preview says so", lines():find("change after a reload", 1, true) ~= nil)
    previewFrame().confirm:Click()
    check("reload: asked after the apply", R.prompt:IsShown() and b:IsShown())
    R.prompt.later:Click()
    check("reload: Later hides both", not R.prompt:IsShown() and not b:IsShown())

    -- Restoring the bars asks again; combat starting hides both.
    A.Commands.restore("1")
    previewFrame().confirm:Click()
    check("reload: asked after a restore of the bars", R.prompt:IsShown() and b:IsShown())
    WoW.fire("PLAYER_REGEN_DISABLED")
    check("reload: combat start hides both", not R.prompt:IsShown() and not b:IsShown())
    G.combat = true
    check("reload: never opens in combat", A.Reload.Ask("x") == false and not b:IsShown())
    G.combat = false

    -- #91 review: an apply that stops after writing the bars still asks,
    -- and keeps its backup pinned.
    boot()
    R = A.Reload._test
    A.Catalog.Create("ui", { name = "Both" }, { bars = { [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = false, [7] = false, [8] = false }, cvars = { damageMeterEnabled = "1", damageMeterResetOnNewInstance = "1" } })
    -- Bars, then damageMeterEnabled, are written; the next setting refuses.
    UI.after["SetActionBarToggles"] = function() UI.cvarInfo.damageMeterResetOnNewInstance = { secure = true } end
    P.Open("ui")
    W.uiApply:Click()
    previewFrame().confirm:Click()
    local _, op = A.Backups.List()
    check("reload: partial apply stopped, pin kept", op ~= nil and UI.bars[1] == true)
    check("reload: asked after a partial apply", R.prompt:IsShown() and R.button:IsShown())
    R.prompt.later:Click()
    UI.after = {}
    UI.cvarInfo.damageMeterResetOnNewInstance = nil
    -- Its restore puts the bars back, then stops on damageMeterEnabled: still asked.
    UI.after["SetActionBarToggles"] = function() UI.cvarInfo.damageMeterEnabled = { secure = true } end
    WoW.chatLines = {}
    A.Commands.restore("op")
    previewFrame().confirm:Click()
    check("reload: the restore stopped", table.concat(WoW.chat(), " "):find("Stopped", 1, true) ~= nil)
    check("reload: asked after a partial restore", R.prompt:IsShown() and not UI.bars[1])
    UI.after = {}

    -- An apply that doesn't touch the bars doesn't ask.
    boot()
    R = A.Reload._test
    A.Catalog.Create("ui", { name = "Meter" }, { cvars = { damageMeterEnabled = "1" } })
    P.Open("ui")
    W.uiApply:Click()
    previewFrame().confirm:Click()
    eq("reload: no bars, no prompt", R.prompt:IsShown(), false)
end

finish("test_uisetup_panel")
