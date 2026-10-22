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
                         "Ready.lua", "Loadout.lua", "UISetup.lua", "Preview.lua", "Commands.lua", "Panel.lua" }) do
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

finish("test_uisetup_panel")
