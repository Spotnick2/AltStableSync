------------------------------------------------------------
-- test_probe_audit.lua - AltStableSyncProbe's audit procedure (#95)
--
-- The UI parts in the independent record (layout, bar toggles, CVars, chat
-- windows, meter windows, the backups by name), their comparison with the
-- declared exceptions (created tabs kept, the meter part left on Forever),
-- and `/fp steps sync audit` driven end to end through the host: a UI setup
-- and a loadout applied, a full exit, both restored by name, a second full
-- exit, the short checks. The probe only reads.
--
-- Needs a ForeverProbe checkout ($FOREVERPROBE, else ..\ForeverProbe). It is
-- private and local, so CI (FOREVERPROBE_OPTIONAL=1) skips this file.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")

local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
do
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            print("test_probe_audit: SKIPPED (no ForeverProbe checkout; probe tests run locally)")
            os.exit(0)
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    toc:close()
end

local G, UI = WoW.game, WoW.ui
WoW.reset()

function UnitRace() return "Human", "Human" end
function UnitLevel() return 40 end
function GetShapeshiftForm() return 0 end
function GetBonusBarOffset() return 0 end
local shots = 0
function Screenshot() shots = shots + 1 end
local errors = {}
function geterrorhandler() return function(e) errors[#errors + 1] = tostring(e) end end
SlashCmdList = SlashCmdList or {}
local function shoot()
    for _ = 1, 8 do
        WoW.clock = WoW.clock + 0.5
        WoW.now = WoW.now + 1
        for _, f in ipairs(WoW.frames) do
            local h = f.scripts.OnUpdate
            if h then h(f, 0.5) end
        end
    end
    WoW.fire("SCREENSHOT_SUCCEEDED")
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end

-- AltStableSync as the probe sees it: read paths only, every write a trap;
-- a ring the "operations" below push into.
local ready, writes = true, {}
local function trap(name) return function() writes[#writes + 1] = name; error("write path " .. name, 2) end end
local ring = {}
local function backup(reason, kind)
    WoW.now = WoW.now + 60
    table.insert(ring, 1, { at = WoW.now, reason = reason, kind = kind, op = { kind = kind or "load", name = reason } })
end
AltStableSync = {
    SCHEMA = 12,
    Ready = { IsReady = function() if ready then return true end return false, "still loading" end },
    Backups = { List = function() return ring, nil end, Pin = trap("Backups.Pin"), PushRing = trap("Backups.PushRing"),
                Release = trap("Backups.Release") },
    Commands = { LoadEntry = trap("Commands.LoadEntry") },
    Loadout = { Load = trap("Loadout.Load"), Restore = trap("Loadout.Restore") },
    UISetup = { Apply = trap("UISetup.Apply"), Restore = trap("UISetup.Restore") },
    Catalog = { Create = trap("Catalog.Create"), Replace = trap("Catalog.Replace") },
    Link = { state = "on" },
}
AltStableSyncDB = { presets = {} }
AltStableSyncChar = {}

local ME = "Player-70-AUD1T"
G.setup{
    guid = ME, class = "PRIEST",
    spells = { { id = 2061, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" } },
    macros = { { name = "Heal", body = "/cast Heal", char = true } },
    actions = { [1] = { spell = 2061 }, [4] = { macro = "Heal" } },
    keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2", ["SHIFT-1"] = "ACTIONBUTTON1" },
}
UI.setup()

------------------------------------------------------------
-- Load the host and the probe, as the client does
------------------------------------------------------------

local files = {}
for line in io.open(root .. "/ForeverProbe.toc", "rb"):read("*a"):gmatch("[^\r\n]+") do
    if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = root .. "/" .. line end
end
for _, f in ipairs(files) do assert(loadfile(f))("ForeverProbe", {}) end
WoW.fire("ADDON_LOADED", "ForeverProbe")
local NS = {}
for line in io.lines("Tools/AltStableSyncProbe/AltStableSyncProbe.toc") do
    line = line:gsub("\r", "")
    if line:match("%.lua$") and not line:match("^#") then
        assert(loadfile("Tools/AltStableSyncProbe/" .. line))("AltStableSyncProbe", NS)
    end
end
WoW.fire("ADDON_LOADED", "AltStableSyncProbe")
WoW.fire("PLAYER_LOGIN")

local FP = ForeverProbe
local S = FP.Steps
local DB = AltStableSyncProbeDB
local function fp(msg) SlashCmdList.FOREVERPROBE(msg) end

------------------------------------------------------------
-- The UI parts in the record
------------------------------------------------------------

backup("an earlier load", "load")
local r = NS.Record()
check("the record is complete", r.valid, table.concat(r.why, "; "))
eq("nothing in the UI unread", #r.ui.why, 0, table.concat(r.ui.why, "; "))
eq("layout: the active preset by name", r.ui.layout.name, "Modern")
eq("layout: its type", r.ui.layout.type, 0)
eq("layout: its index", r.ui.layout.index, 1)
eq("bar toggles 2-8", r.ui.bars, "0000000")
eq("a CVar", r.ui.cvars.damageMeterEnabled, "0")
eq("General by slot", r.ui.chat[1].name, "General")
eq("its groups, sorted", r.ui.chat[1].groups, "BN_WHISPER,CHANNEL,EMOTE,GUILD,PARTY,SAY,SYSTEM,WHISPER,YELL")
eq("the Combat Log is active (docked) too", r.ui.chat[2].name, "Combat Log")
eq("no meter manager on this client: skipped", r.ui.meter, nil)
eq("the backups by name", r.addon.backups[1].reason, "an earlier load")
eq("reading never writes", #G.calls, 0)

------------------------------------------------------------
-- Comparing UI parts, with the declared exceptions
------------------------------------------------------------

local FULL = { tabs = {}, meter = false }
do
    local a = NS.Record()
    check("same state: equal with UI", NS.Compare(a, NS.Record(), nil, FULL).equal)
    UI.active = 4
    local c = NS.Compare(a, NS.Record(), nil, FULL)
    eq("layout change named", c.diffs[1], "layout: Modern (type 0, index 1) -> My UI (type 1, index 4)")
    check("without `ui` the stress comparison ignores it", NS.Compare(a, NS.Record()).equal)
    UI.active = 1
    UI.bars[1] = true
    eq("bars change named", NS.Compare(a, NS.Record(), nil, FULL).diffs[1], "bar toggles 2-8: 0000000 -> 1000000")
    UI.bars[1] = false
    UI.cvars.damageMeterEnabled = "1"
    eq("CVar change named", NS.Compare(a, NS.Record(), nil, FULL).diffs[1], "cvar damageMeterEnabled: 0 -> 1")
    UI.cvars.damageMeterEnabled = "0"
    UI.windows[4] = { name = "Whispers", shown = false, docked = true, uninteractable = false, groups = { "WHISPER", "BN_WHISPER" } }
    c = NS.Compare(a, NS.Record(), nil, FULL)
    eq("a new tab is a difference", c.diffs[1], "chat window 4: none -> Whispers: BN_WHISPER,WHISPER")
    c = NS.Compare(a, NS.Record(), nil, { tabs = { Whispers = true }, meter = false })
    check("a created tab is an allowed, named exception", c.equal and c.info[1] == "chat tab kept, as expected: Whispers", c.info[1])
    UI.windows[4] = { name = "", shown = false, docked = false, uninteractable = false, groups = {} }
    -- The meter part, from hand-made records (no manager in these stubs).
    local function rec(meter)
        return { valid = true, guid = ME, set = 2, slots = {}, raw = {}, special = {}, macros = {}, keymap = {}, cmdkeys = {},
                 ui = { why = {}, cvars = {}, meter = meter } }
    end
    local x = rec({ "shown type 0 session 0 unlocked 100,500 400x200" })
    local y = rec({ "shown type 0 session 1 locked 100,500 400x200", "shown type 2 session 1 locked 300,400 400x200" })
    c = NS.Compare(x, y, nil, FULL)
    eq("meter differences named", #c.diffs, 2)
    c = NS.Compare(x, y, nil, { tabs = {}, meter = true })
    check("the whole meter part is an allowed, named exception", c.equal and #c.info == 2 and c.info[1]:find("as applied, as expected", 1, true) ~= nil, c.info[1])
    local z = rec(nil)
    c = NS.Compare(x, z, nil, FULL)
    check("meter unreadable on one side: unverified", not c.equal and c.unverified[1] == "meter windows unreadable on one side", c.unverified[1])
    y.ui = nil
    check("no UI parts recorded: unverified", NS.Compare(x, y, nil, FULL).unverified[1] == "UI parts not recorded")
end

------------------------------------------------------------
-- The procedure, end to end
------------------------------------------------------------

local AAT = NS.AAT
local function rec() return ForeverProbeDB.steps.records["AltStableSyncProbe/audit"] end
local function at() return rec().at end
local function result(i) return rec().results[i] end
local function pass(i, what) eq(what .. " passes", result(i).check, "PASS", result(i).checkDetail) end

fp("steps sync audit")
check("/fp steps sync audit starts it", rec() and rec().status == "active")
S.Run()                                              -- 1 Start
eq("the audit is on this character", DB.audit and DB.audit.guid, ME)
S.Next()                                             -- 2 set up
G.keys["CTRL-F11"] = "TOGGLEAUTORUN"                 -- 3: the other addon's unsaved key
S.Next()
S.Run(); shoot()                                     -- 4 before
check("before recorded", DB.audit.records.before and DB.audit.records.before.valid)

-- 5: the owner applies U: layout, a bar, a setting, a group, a new tab.
UI.active = 4
UI.bars[1] = true
UI.cvars.damageMeterEnabled = "1"
table.insert(UI.windows[1].groups, "COMBAT_XP_GAIN")
UI.windows[4] = { name = "Whispers", shown = false, docked = true, uninteractable = false, groups = { "WHISPER", "BN_WHISPER" } }
backup("UI setup U", "ui")
S.Next()
S.Answer(true)                                       -- 6 applied
S.Run(); shoot()                                     -- 7 afterUI
pass(7, "the UI setup changed UI parts and nothing else")

-- 8: the owner loads L: a spell placed, a key taken, Heal updated, Aegis
-- created, every key saved (CTRL-F11 included: the declared D3 exception).
G.actions[2] = { kind = "spell", id = 2050 }
G.keys["Q"] = "ACTIONBUTTON3"
G.char[1].body = "/cast Heal\n/say healing"
table.insert(G.char, { name = "Aegis", icon = 134400, body = "/cast Power Word: Shield" })
G.sortMacros()
G.savedKeys = copy(G.keys)
backup("load L", "load")
S.Next()
S.Answer(true)                                       -- 9 loaded
S.Run(); shoot()                                     -- 10 afterLoad
pass(10, "the loadout changed game state and no UI part")
check("the record lists the backups by name", DB.audit.records.afterLoad.addon.backups[1].reason == "load L"
      and DB.audit.records.afterLoad.addon.backups[2].reason == "UI setup U")

-- 11: the first full exit.
FP.run = FP.run + 1
WoW.relaunch()
S.Resume()
eq("back at the exit question", at(), AAT.exit1)
S.Answer(true)                                       -- 12
S.Run()                                              -- 13 exit1
pass(13, "everything applied persisted")
S.Run()                                              -- 14 CTRL-F11 still bound
pass(14, "the other addon's key was saved by our load (D3)")
S.Answer(true)                                       -- 15 bars as the setup says

-- 16: the owner restores "load L": the spell and key back, Heal back, Aegis kept.
G.actions[2] = nil
G.keys["Q"] = nil
for _, m in ipairs(G.char) do if m.name == "Heal" then m.body = "/cast Heal" end end
G.savedKeys = copy(G.keys)
backup("restore", "load")
S.Next()
S.Answer(true)                                       -- 17
S.Run(); shoot()                                     -- 18 afterRestoreL
pass(18, "the loadout's restore is exact except the kept macro")

-- 19: the owner restores "UI setup U": the tab stays.
UI.active = 1
UI.bars[1] = false
UI.cvars.damageMeterEnabled = "0"
for i, g in ipairs(UI.windows[1].groups) do if g == "COMBAT_XP_GAIN" then table.remove(UI.windows[1].groups, i) break end end
backup("restore", "ui")
S.Next()
S.Answer(true)                                       -- 20
S.Run(); shoot()                                     -- 21 afterRestoreU
pass(21, "the UI setup's restore is exact except the kept tab")

-- 22: the second full exit.
FP.run = FP.run + 1
WoW.relaunch()
S.Resume()
eq("back at the second exit question", at(), AAT.exit2)
S.Answer(true)                                       -- 23
S.Run()                                              -- 24 exit2
pass(24, "both restores persisted")
S.Answer(true)                                       -- 25 bars as before

-- 26: a third key on button 1.
G.keys["CTRL-F10"] = "ACTIONBUTTON1"
S.Run()
pass(26, "three keys on one command")
G.keys["CTRL-F10"], G.keys["CTRL-F11"] = nil, nil
S.Next()                                             -- 27 unbind

-- 28-29: a restore under Account bindings.
G.actions[2] = { kind = "spell", id = 2050 }
G.keys["Q"] = "ACTIONBUTTON3"
G.bindingSet = 1
S.Run()                                              -- 28 accountBefore
G.actions[2] = nil                                   -- the restore puts the slot back, keys untouched
S.Run()                                              -- 29 accountAfter
pass(29, "a restore under Account bindings moved actions and no key")

FP.run = FP.run + 1
S.Resume()                                           -- 30 /reload
eq("finished", rec().status, "done")
eq("five screenshots", shots, 5)

------------------------------------------------------------
-- What the probe never does, and what the checks refuse
------------------------------------------------------------

eq("no mutating game call", #G.calls, 0, table.concat(G.calls, ", "))
eq("no AltStableSync write path", #writes, 0, table.concat(writes, ", "))
eq("nothing in chat", #WoW.chat(), 0, table.concat(WoW.chat(), " | "))

do
    local R = DB.audit.records
    local keep = { afterUI = R.afterUI, afterLoad = R.afterLoad, afterRestoreL = R.afterRestoreL, afterRestoreU = R.afterRestoreU }
    -- A "loadout" that changed a UI part fails.
    local bad = copy(R.afterLoad); bad.ui.bars = "1111111"
    R.afterLoad = bad
    check("a loadout that changed a UI part fails", not NS._audit.gameChanged())
    R.afterLoad = keep.afterLoad
    -- A UI restore that left a CVar fails; one that left only the tab passes.
    bad = copy(R.afterRestoreU); bad.ui.cvars.damageMeterEnabled = "1"
    R.afterRestoreU = bad
    check("a UI restore that left a setting fails", not NS._audit.restoredU())
    R.afterRestoreU = keep.afterRestoreU
    check("the real records pass", NS._audit.restoredU() and NS._audit.restoredL())
    -- A loadout restore that left a key fails.
    bad = copy(R.afterRestoreL); bad.keymap["Q"] = "ACTIONBUTTON3"
    R.afterRestoreL = bad
    check("a loadout restore that left a key fails", not NS._audit.restoredL())
    R.afterRestoreL = keep.afterRestoreL
    -- The restore under Account bindings must not touch a key.
    local before, after = R.accountBefore, copy(R.accountAfter)
    after.keymap["Q"] = nil
    R.accountAfter = after
    check("an Account restore that unbound a key fails", not NS._audit.accountRestore())
    R.accountAfter = keep.accountAfter or R.accountAfter
end

finish("test_probe_audit")
