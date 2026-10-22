------------------------------------------------------------
-- test_offer.lua - the first-login offer (#10): when it appears, what each
-- answer records, and that it never writes game state or the catalog.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")

local G, UI = WoW.game, WoW.ui
local A, O

local BARS = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = false, [7] = false, [8] = false }

local function boot(opts)
    opts = opts or {}
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "UISetup.lua", "Preview.lua", "Reload.lua", "Commands.lua", "Panel.lua",
                         "Offer.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    AltStableSyncChar = opts.char
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A, O = AltStableSync, AltStableSync.Offer
    G.setup{ class = "MAGE", guid = "Player-70-NEW", spells = { { id = 133, name = "Fireball" } } }
    UI.setup()
    for _, s in ipairs(opts.setups or {}) do
        A.Catalog.Create("ui", { name = s.name, provenance = s.provenance }, { bars = BARS })
    end
    UI.calls = {}
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
end

local frame = function() return _G.AltStableSyncPreview end
local function offer() local s = A.Preview.Shown(); return s and s.title == "Welcome" and s end
local function tick(n) for _ = 1, n or 1 do O._Tick(nil, 1.1) end end
local function settle() WoW.clock = WoW.clock + 10; tick() end

-- Not ready yet: no offer; ready: offered once, writing nothing.
do
    boot{ setups = { { name = "Base" } } }
    tick()
    check("not ready: no offer", not offer())
    local db = A.Catalog.Copy(AltStableSyncDB)
    settle()
    local o = offer()
    check("ready: offered", o ~= nil)
    check("one setup: named", o and table.concat(o.lines, " "):find("saved UI preferences: Base.", 1, true) ~= nil)
    eq("one setup: Preview and apply", o and o.confirm, "Preview and apply")
    eq("Not now label", frame().cancel:GetText(), "Not now")
    eq("offer: no game writes", #UI.calls, 0)
    check("offer: no catalog writes", A.UISetup.Serialize(AltStableSyncDB.presets) == A.UISetup.Serialize(db.presets))
    check("offer: not answered yet", AltStableSyncChar.onboarding == nil)
end

-- Not now: answered, never offered again on this character.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame().cancel:Click()
    check("not now: handled", AltStableSyncChar.onboarding and AltStableSyncChar.onboarding.handled == true)
    eq("not now: no game writes", #UI.calls, 0)
    local char = AltStableSyncChar
    boot{ setups = { { name = "Base" } }, char = char }
    settle(); tick(5)
    check("next login: no offer", not offer())
end

-- Escape is no answer: the offer comes back next login.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame():Hide()
    check("escape: not handled", AltStableSyncChar.onboarding == nil)
    local char = AltStableSyncChar
    tick(5)
    check("escape: not again this session", not offer())
    boot{ setups = { { name = "Base" } }, char = char }
    settle()
    check("escape: offered at the next login", offer() ~= nil)
end

-- Preview and apply: the apply preview opens (answered); its confirm writes.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame().confirm:Click()
    local s = A.Preview.Shown()
    check("preview: the apply preview is open", s and s.title == "Apply Base?")
    check("preview: handled once it opened", AltStableSyncChar.onboarding and AltStableSyncChar.onboarding.handled)
    eq("preview: nothing written yet", #UI.calls, 0)
    frame().confirm:Click()
    check("preview: applied on its confirm", UI.bars[1] == true)
end

-- Several setups: Choose opens the UI setup tab.
do
    boot{ setups = { { name = "Base" }, { name = "Healer" } } }
    settle()
    local o = offer()
    eq("several: Choose", o and o.confirm, "Choose")
    frame().confirm:Click()
    check("choose: the tab is open", A.Panel._Frame() and A.Panel._Frame():IsShown() and A.Panel.view == "ui")
    check("choose: handled", AltStableSyncChar.onboarding and AltStableSyncChar.onboarding.handled)
end

-- Never offered: no setup, only this character's own, a conflict copy,
-- combat, Edit Mode open, another preview open.
do
    boot()
    settle(); tick(3)
    check("none saved: no offer", not offer())

    boot{ setups = { { name = "Mine", provenance = { sourceChar = "Karuzo-Elegia" } } } }
    settle(); tick(3)
    check("own setup only: no offer", not offer())

    boot{ setups = { { name = "Base" } } }
    G.combat = true
    settle(); tick(3)
    check("combat: waits", not offer())
    G.combat = false
    tick()
    check("combat over: offered", offer() ~= nil)

    boot{ setups = { { name = "Base" } } }
    UI.editMode = true
    settle()
    check("edit mode: waits", not offer())

    boot{ setups = { { name = "Base" } } }
    A.Preview.Show({ title = "Something else", lines = {} })
    settle()
    eq("another preview: left alone", A.Preview.Shown().title, "Something else")
end

-- A setup that arrives later in the session (sync) is offered then.
do
    boot()
    settle(); tick(3)
    check("later: nothing yet", not offer())
    A.Catalog.Create("ui", { name = "Arrived" }, { bars = BARS })
    tick()
    check("later: offered", offer() ~= nil)
end

-- /altsync ui offer shows it again for testing, without recording an answer.
do
    boot{ setups = { { name = "Base" } }, char = { schema = A and A.SCHEMA or 10, onboarding = { handled = true } } }
    settle()
    check("forced: not offered by itself", not offer())
    A.Commands.ui("offer")
    check("forced: shown", offer() ~= nil)
    AltStableSyncChar.onboarding = nil
    frame().cancel:Click()
    check("forced: Not now records nothing", AltStableSyncChar.onboarding == nil)
    A.Preview.Show({ title = "Something else", lines = {} })
    A.Commands.ui("offer")
    eq("forced: never over another preview", A.Preview.Shown().title, "Something else")
end

finish("test_offer")
