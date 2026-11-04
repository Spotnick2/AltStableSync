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
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Share.lua", "Backups.lua",
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
    eq("Skip label", frame().cancel:GetText(), "Skip...")
    eq("offer: no game writes", #UI.calls, 0)
    check("offer: no catalog writes", A.UISetup.Serialize(AltStableSyncDB.presets) == A.UISetup.Serialize(db.presets))
    check("offer: not answered yet", AltStableSyncChar.onboarding == nil)
end

local function title() local x = A.Preview.Shown(); return x and x.title end
local function answered() return AltStableSyncChar.onboarding ~= nil and AltStableSyncChar.onboarding.handled == true end

-- Owner, 2026-10-22: Escape asks for confirmation, and a confirmed skip or a
-- completed apply are the only answers.
-- Escape on the Welcome -> the confirmation; Skip setup answers for good.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame():Hide()
    check("escape: not answered", not answered())
    O._Flush()
    eq("escape: the confirmation", title(), "Skip setting up?")
    eq("confirmation: Skip setup", frame().confirm:GetText(), "Skip setup")
    eq("confirmation: Back", frame().cancel:GetText(), "Back")
    frame().confirm:Click()
    O._Flush()
    check("skip setup: answered", answered())
    check("skip setup: nothing more shown", A.Preview.Shown() == nil)
    eq("skip setup: no game writes", #UI.calls, 0)
    local char = AltStableSyncChar
    boot{ setups = { { name = "Base" } }, char = char }
    settle(); tick(5)
    check("next login: no offer", not offer())
end

-- Skip... is the same as Escape; Back returns to the Welcome; Escape on the
-- confirmation closes it unanswered, and the offer returns next login.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame().cancel:Click()
    O._Flush()
    eq("skip button: the confirmation", title(), "Skip setting up?")
    frame().cancel:Click()
    O._Flush()
    eq("back: the Welcome again", title(), "Welcome")
    frame():Hide(); O._Flush()
    frame():Hide(); O._Flush()
    check("escape twice: closed", A.Preview.Shown() == nil)
    check("escape twice: not answered", not answered())
    tick(5)
    check("escape twice: not again this session", not offer())
    local char = AltStableSyncChar
    boot{ setups = { { name = "Base" } }, char = char }
    settle()
    check("escape twice: offered at the next login", offer() ~= nil)
end

-- Preview and apply: nothing recorded until the apply completes; Cancel or
-- Escape on the apply preview returns to the Welcome.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame().confirm:Click()
    eq("preview: the apply preview is open", title(), "Apply Base?")
    check("preview: not answered by opening it", not answered())
    frame().cancel:Click()
    O._Flush()
    eq("preview cancelled: the Welcome again", title(), "Welcome")
    frame().confirm:Click()
    frame():Hide()
    O._Flush()
    eq("preview escaped: the Welcome again", title(), "Welcome")
    frame().confirm:Click()
    eq("preview: nothing written yet", #UI.calls, 0)
    frame().confirm:Click()
    O._Flush()
    check("apply: written on its confirm", UI.bars[1] == true)
    check("apply: answered", answered())
    check("apply: the Welcome doesn't come back", title() ~= "Welcome")
end

-- An apply that stops doesn't answer; one that completed stays answered
-- through a later stopped apply, a restore and a deleted setup. Save As
-- alone never answers.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    -- The bars don't read back as written: the apply stops there.
    UI.after["SetActionBarToggles"] = function() UI.bars[1] = false end
    frame().confirm:Click()
    frame().confirm:Click()
    UI.after = {}
    check("stopped apply: stopped", table.concat(WoW.chat(), " "):find("Stopped", 1, true) ~= nil)
    check("stopped apply: not answered", not answered())

    boot{ setups = { { name = "Base" } } }
    settle()
    frame().confirm:Click()
    frame().confirm:Click()
    check("completed: answered", answered())
    local base = A.Catalog.ListAll("ui")[1]
    A.Catalog.Create("ui", { name = "Other" }, { cvars = { damageMeterEnabled = "1" } })
    UI.after["SetCVar:damageMeterEnabled"] = function() G.combat = true end
    A.Commands.ui("apply Other")
    frame().confirm:Click()
    G.combat = false
    UI.after = {}
    check("later stopped apply: still answered", answered())
    A.Commands.restore("op")
    frame().confirm:Click()
    check("restore: still answered", answered())
    A.Catalog.Delete(base.id, base.version)
    check("deleted setup: still answered", answered())

    boot{ setups = { { name = "Base" } } }
    A.Commands.ui("saveas Mine")
    frame().confirm:Click()
    check("save as: not answered", not answered())
end

-- Choose opens the tab and answers nothing.
do
    boot{ setups = { { name = "Base" }, { name = "Healer" } } }
    settle()
    local o = offer()
    eq("several: Choose", o and o.confirm, "Choose")
    frame().confirm:Click()
    check("choose: the tab is open", A.Panel._Frame() and A.Panel._Frame():IsShown() and A.Panel.view == "ui")
    check("choose: not answered", not answered())
end

-- Beta, 2026-10-22: on a new character an addon rewriting its macro kept the
-- readiness gate closed, and the confirmation never came. A step only shows
-- our own window: it doesn't wait for readiness.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame():Hide()
    WoW.fire("UPDATE_MACROS")               -- RestedXP updating its targeting macro
    O._Flush()
    eq("step while macros update: the confirmation", title(), "Skip setting up?")
end

-- A pending step is dropped in combat, or when another preview took the frame.
do
    boot{ setups = { { name = "Base" } } }
    settle()
    frame():Hide()
    G.combat = true
    O._Flush()
    check("step in combat: dropped", A.Preview.Shown() == nil)
    G.combat = false
    boot{ setups = { { name = "Base" } } }
    settle()
    frame():Hide()
    A.Preview.Show({ title = "Something else", lines = {} })
    O._Flush()
    eq("step: never over another preview", title(), "Something else")
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
    -- The character stays answered; a marker shows the record is never rewritten.
    AltStableSyncChar.onboarding.marker = "kept"
    frame().cancel:Click()
    O._Flush()
    eq("forced: the confirmation", title(), "Skip setting up?")
    frame().cancel:Click()
    O._Flush()
    eq("forced: Back works on an answered character", title(), "Welcome")
    frame().cancel:Click()
    O._Flush()
    frame().confirm:Click()
    check("forced: Skip setup records nothing", AltStableSyncChar.onboarding.marker == "kept")
    A.Preview.Show({ title = "Something else", lines = {} })
    A.Commands.ui("offer")
    eq("forced: never over another preview", A.Preview.Shown().title, "Something else")
end

finish("test_offer")
