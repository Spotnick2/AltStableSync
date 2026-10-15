------------------------------------------------------------
-- test_probe.lua - AltStableSyncProbe, the ForeverProbe module (#85)
--
-- The independent record (slots, macros, every bound key, the pet bar) and
-- its comparison, then the stress procedure driven end to end through the
-- host's steps: two characters, a Load each, a full exit, a Restore, another
-- full exit. The probe only reads: no mutating game call, no AltStableSync
-- write path, nothing in chat.
--
-- Needs a ForeverProbe checkout ($FOREVERPROBE, else ..\ForeverProbe). It is
-- private and local, so CI (FOREVERPROBE_OPTIONAL=1) skips this file.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
do
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            print("test_probe: SKIPPED (no ForeverProbe checkout; probe tests run locally)")
            os.exit(0)
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    toc:close()
end

local G = WoW.game
WoW.reset()

------------------------------------------------------------
-- The client beyond the shared stubs
------------------------------------------------------------

function UnitRace() return "Human", "Human" end
function UnitLevel() return 40 end
function GetShapeshiftForm() return 0 end
function GetBonusBarOffset() return 0 end
local shots = 0
function Screenshot() shots = shots + 1 end
local errors = {}
function geterrorhandler() return function(e) errors[#errors + 1] = tostring(e) end end
SlashCmdList = SlashCmdList or {}

-- The host shoots from its frames' OnUpdate; the test owns the clock.
local function shoot()
    for _ = 1, 8 do
        WoW.clock = WoW.clock + 0.5
        WoW.now = WoW.now + 1          -- file names are to the second: the host waits for it to turn
        for _, f in ipairs(WoW.frames) do
            local h = f.scripts.OnUpdate
            if h then h(f, 0.5) end
        end
    end
    WoW.fire("SCREENSHOT_SUCCEEDED")
end

------------------------------------------------------------
-- AltStableSync, as the probe sees it: read paths only, every write path a trap
------------------------------------------------------------

local ready, writes = true, {}
local function trap(name) return function() writes[#writes + 1] = name; error("write path " .. name, 2) end end
AltStableSync = {
    SCHEMA = 9,
    Ready = { IsReady = function() if ready then return true end return false, "macros or bindings still loading" end },
    Backups = { List = function() return { { at = 1760000100, op = { kind = "loadout", id = "loadout-x-1", name = "Everyday" } } }, nil end,
                Pin = trap("Backups.Pin"), PushRing = trap("Backups.PushRing"), Release = trap("Backups.Release") },
    Commands = { LoadEntry = trap("Commands.LoadEntry") },
    Loadout = { Apply = trap("Loadout.Apply"), Restore = trap("Loadout.Restore") },
    Catalog = { Create = trap("Catalog.Create"), Replace = trap("Catalog.Replace"), Delete = trap("Catalog.Delete") },
    Link = { state = "on" },
}
AltStableSyncDB = { presets = { ["loadout-a-1"] = { id = "loadout-a-1", kind = "loadout", name = "Everyday" } } }
AltStableSyncChar = { loaded = { loadout = { id = "loadout-a-1", version = "a:1", result = { at = 1760000100 } } } }

------------------------------------------------------------
-- Two characters, swapped in and out of the game model
------------------------------------------------------------

local FIRST, SECOND = "Player-70-0000F1F1", "Player-70-0000S2S2"
local function character(guid, opts)
    G.setup({
        guid = guid, class = "HUNTER",
        spells = { { id = 75, name = "Auto Shot" }, { id = 1978, name = "Serpent Sting" }, { id = 3044, name = "Arcane Shot" } },
        macros = opts.macros or { { name = "Pet", body = "/petattack", char = true }, { name = "Mount", body = "/use Horse" } },
        actions = opts.actions or { [1] = { spell = 75 }, [2] = { spell = 1978 }, [3] = { macro = "Pet" }, [150] = { spell = 3044 } },
        keys = opts.keys or { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2", ["F"] = "TOGGLEAUTORUN",
                              ["CTRL-5"] = "CLICK MyBar:LeftButton" },
        pet = opts.pet,
        bindingSet = opts.bindingSet,
    })
end

-- What's saved per character across "logins" in this test (the server's copy).
local saved = {}
local function save(guid)
    saved[guid] = { actions = G.actions, account = G.account, char = G.char, keys = G.keys, pet = G.pet,
                    bindingSet = G.bindingSet }
end
local function login(guid)
    local s = saved[guid]
    G.guid, G.actions, G.account, G.char, G.keys, G.savedKeys, G.pet, G.bindingSet =
        guid, s.actions, s.account, s.char, s.keys, s.keys, s.pet, s.bindingSet
end

local BEAR = { family = 4, familyName = "Bear", name = "Grizzly",
               bar = { [1] = { token = "PET_ACTION_ATTACK" }, [4] = { spell = 2649, autocast = true } },
               book = { { id = 2649, name = "Growl" } } }

-- Both characters exist before anything loads (G.setup resets the call log).
character(SECOND, { actions = { [1] = { spell = 75 } } })
save(SECOND)
character(FIRST, { pet = BEAR })
save(FIRST)

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
local function logHas(text)
    for _, l in ipairs(DB.log) do if tostring(l):find(text, 1, true) then return true end end
    return false
end

check("the saved table is made at the probe's ADDON_LOADED", type(DB) == "table" and type(DB.log) == "table")
check("its load line is in the saved log", logHas("loaded (1 loads)"))

------------------------------------------------------------
-- The record and the comparison
------------------------------------------------------------

local r1 = NS.Record()
check("a record is complete", r1.valid, table.concat(r1.why, "; "))
eq("it names the character", r1.guid, FIRST)
eq("slot 1 by spell", r1.slots[1], "spell:75:spell")
eq("a macro slot by its macro, not its shown id", r1.slots[3], "macro:character:Pet")
eq("an empty slot", r1.slots[4], false)
eq("Action Bar 6 is compared too", r1.slots[150], "spell:3044:spell")
eq("two macros", #r1.macros, 2)
eq("a custom CLICK binding is read by key", r1.keymap["CTRL-5"], "CLICK MyBar:LeftButton")
eq("an unmanaged key is read", r1.keymap["F"], "TOGGLEAUTORUN")
eq("the binding list too", r1.cmdkeys["ACTIONBUTTON1"], "1")
eq("the pet by family", r1.pet and r1.pet.family, 4)
eq("its command slot", r1.pet and r1.pet.slots[1], "token:PET_ACTION_ATTACK")
eq("its ability slot", r1.pet and r1.pet.slots[4], "spell:2649")
eq("its autocast", r1.pet and r1.pet.autocast[4], true)

check("a record equals itself", NS.Compare(r1, NS.Record()).equal)

-- The time and AltStableSync's own records are evidence, never compared.
do
    WoW.now = WoW.now + 500
    AltStableSyncChar.loaded.loadout.version = "a:2"
    local c = NS.Compare(r1, NS.Record())
    check("a later time and another addon record still compare equal", c.equal)
    WoW.now = WoW.now - 500
    AltStableSyncChar.loaded.loadout.version = "a:1"
end

-- The macro's shown spell (its raw id) changes with a target or a form: not a difference.
G.char[1].shows = 2649
check("a macro slot's raw id changing is no difference", NS.Compare(r1, NS.Record()).equal)
G.char[1].shows = nil

-- A key a Load took over (F: autorun -> button 1), then left unbound by a broken Restore.
do
    G.keys["F"] = nil
    local c = NS.Compare(r1, NS.Record())
    check("a displaced key left unbound is a difference", not c.equal and #c.diffs > 0)
    G.keys["F"] = "TOGGLEAUTORUN"
end

-- A custom binding changed.
G.keys["CTRL-5"] = "CLICK OtherBar:LeftButton"
check("a changed custom binding is a difference", not NS.Compare(r1, NS.Record()).equal)
G.keys["CTRL-5"] = "CLICK MyBar:LeftButton"

-- Another binding set.
G.bindingSet = 1
check("another binding set is a difference", not NS.Compare(r1, NS.Record()).equal)
G.bindingSet = 2

-- The pet bar.
G.pet.bar[1] = nil
check("a pet command slot emptied is a difference", #NS.Compare(r1, NS.Record()).diffs > 0)
G.pet.bar[1] = { token = "PET_ACTION_ATTACK" }
G.pet.bar[4] = nil
check("a pet slot changed is a difference", #NS.Compare(r1, NS.Record()).diffs > 0)
G.pet.bar[4] = { spell = 2649, autocast = false }
check("autocast changed is a difference", #NS.Compare(r1, NS.Record()).diffs > 0)
G.pet.bar[4] = { spell = 2649, autocast = true }
do
    local pet = G.pet
    G.pet = nil
    local c = NS.Compare(r1, NS.Record())
    check("no pet out: the pet bar isn't comparable, so not equal", not c.equal and #c.unverified == 1)
    G.pet = pet
end

-- Duplicate macro names: which one a slot holds can't be told.
do
    table.insert(G.account, { name = "Pet", icon = 134400, body = "/cast Growl" })
    G.sortMacros()
    local r = NS.Record()
    eq("a macro name held twice: the slot is ambiguous", r.slots[3], "macro?:Pet")
    local c = NS.Compare(r, NS.Record())
    check("and a comparison through it is unverified", not c.equal and #c.unverified > 0)
    for i, m in ipairs(G.account) do if m.body == "/cast Growl" then table.remove(G.account, i) break end end
end

-- Indices shift when a macro is created; created macros are allowed extras.
do
    table.insert(G.char, { name = "Aaa", icon = 134400, body = "/dance" })
    G.sortMacros()
    local r = NS.Record()
    eq("the created macro shifted Pet's index", r.slots[3], "macro:character:Pet")
    check("without allowing it, it's a difference", not NS.Compare(r1, r).equal)
    check("allowed as an extra, the rest is equal", NS.Compare(r1, r, NS.Extras(r1, r)).equal)
    table.remove(G.char, 1)
end

-- A trailing newline from the server doesn't count.
G.char[1].body = G.char[1].body .. "\n"
check("a trailing newline is no difference", NS.Compare(r1, NS.Record()).equal)
G.char[1].body = "/petattack"

-- Slots 121-144 are information only.
G.actions[130] = { kind = "spell", id = 75 }
do
    local c = NS.Compare(r1, NS.Record())
    check("a special page slot changing is information, not a difference", c.equal and #c.info > 0)
end
G.actions[130] = nil

-- A read that fails makes the record incomplete, and nothing compares equal
-- to it, even when everything compared reads the same.
do
    local form = GetShapeshiftForm
    GetShapeshiftForm = function() error("no form") end
    local r = NS.Record()
    GetShapeshiftForm = form
    check("a failed context read makes the record incomplete", not r.valid)
    local c = NS.Compare(r1, r)
    check("and the comparison unverified, with no difference", not c.equal and #c.diffs == 0 and #c.unverified > 0)
end
G.actionFails = true
do
    local r = NS.Record()
    check("a failed key read makes the record incomplete", not r.valid)
    check("and the comparison unverified", not NS.Compare(r1, r).equal)
end
G.actionFails = nil

------------------------------------------------------------
-- The procedure, end to end
------------------------------------------------------------

local AT = NS.AT
local function rec() return ForeverProbeDB.steps.records["AltStableSyncProbe/stress"] end
local function at() return rec().at end
local function result(i) return rec().results[i] end

fp("steps sync stress")
check("/fp steps sync stress starts it", rec() and rec().status == "active")
eq("step 1", at(), 1)
S.Run()
eq("Start: the rehearsal is on this character", DB.rehearsal and DB.rehearsal.first, FIRST)
eq("its check passes", result(1).check, "PASS")
S.Answer(false)                                      -- 2: nothing changed at login
S.Next()                                             -- 3: keybindings, ready
eq("at the before record", at(), 4)

-- Refusals before reading anything: not ready, then Account keybindings.
ready = false
S.Run()
eq("not ready: the step stays", at(), 4)
check("and the refusal is an error report", #errors == 1 and errors[1]:find("not ready", 1, true) ~= nil, errors[1])
ready = true
G.bindingSet = 1
S.Run()
eq("Account keybindings: the before record refuses", at(), 4)
check("saying why", errors[2] and errors[2]:find("character keybindings are off", 1, true) ~= nil, errors[2])
G.bindingSet = 2
S.Run(); shoot()
eq("recorded, then the screenshot", at(), 5)
check("one screenshot", shots == 1)

-- The owner Loads: a new spell in slot 2, F moved to button 3, a macro created.
G.actions[2] = { kind = "spell", id = 3044 }
G.keys["F"] = "ACTIONBUTTON3"
table.insert(G.char, { name = "Trap", icon = 134400, body = "/cast Freezing Trap" })
G.sortMacros()
save(FIRST)
S.Next()                                             -- 5
S.Answer(true)                                       -- 6: Loaded, as previewed
S.Run(); shoot()                                     -- 7: after Load
eq("the after-Load check passes", result(7).check, "PASS")

-- Evidence is frozen: going Back can't replace it.
do
    local ok, err = pcall(NS.Capture, "first", "before")
    check("before can't be recorded again", not ok and tostring(err):find("already recorded", 1, true) ~= nil, err)
end

S.Next()                                             -- 8: log in the second character
eq("at the second character's before", at(), 9)
S.Run()
eq("still the first character: refused", at(), 9)
login(SECOND)
S.Run()                                              -- 9: second before
eq("the second character's before", at(), 10)
eq("its GUID is fixed", DB.rehearsal.second, SECOND)
G.actions[5] = { kind = "spell", id = 1978 }
save(SECOND)
S.Next()                                             -- 10
S.Answer(true)                                       -- 11
S.Run(); shoot()                                     -- 12
eq("the second after-Load check passes", result(12).check, "PASS")

-- 13: a full exit. The server keeps what was saved; bodies gain a newline.
FP.run = FP.run + 1
login(SECOND); WoW.relaunch(); save(SECOND)
login(FIRST); WoW.relaunch(); save(FIRST)
login(SECOND)
S.Resume()
eq("back after the exit, at the exit question", at(), AT.exit1)
S.Answer(true)                                       -- 14
S.Run()                                              -- 15
eq("the second character's Load persisted", result(15).check, "PASS", result(15).checkDetail)
do
    local ok, err = pcall(NS.Capture, "first", "afterExit")
    check("a first-character record refuses on the second character", not ok and tostring(err):find("isn't the first character", 1, true) ~= nil, err)
end
S.Next()                                             -- 16: log in the first
login(FIRST)
S.Run()                                              -- 17
eq("the first character's Load persisted", result(17).check, "PASS", result(17).checkDetail)

-- 18: the owner Restores: slot 2 and F back; the created macro stays.
G.actions[2] = { kind = "spell", id = 1978 }
G.keys["F"] = "TOGGLEAUTORUN"
save(FIRST)
S.Next()                                             -- 18
S.Answer(true)                                       -- 19: it said restored
S.Run(); shoot()                                     -- 20
eq("Restore is exact (the created macro kept, as expected)", result(20).check, "PASS", result(20).checkDetail)

-- 21: the second full exit.
FP.run = FP.run + 1
WoW.relaunch(); save(FIRST)
S.Resume()
eq("at the second exit question", at(), AT.exit2)
S.Answer(false)                                      -- 22: it was a /reload
S.Run()                                              -- 23
eq("a No to the full exit: not a PASS, whatever the state", result(23).check, "FAIL")
check("saying it's unverified", tostring(result(23).checkDetail):find("unverified", 1, true) ~= nil, result(23).checkDetail)
S.Back(); S.Back()
eq("Back to the question", at(), AT.exit2)
S.Answer(true)
do
    local ok, err = pcall(NS.Capture, "first", "afterRestoreExit")
    check("the record already taken is frozen", not ok and tostring(err):find("already recorded", 1, true) ~= nil, err)
end
S.Next()                                             -- past the record: its check runs again on Next
eq("with a Yes, the same record passes", result(23).check, "PASS", result(23).checkDetail)

FP.run = FP.run + 1
S.Resume()                                           -- 24: /reload
eq("finished", rec().status, "done")

------------------------------------------------------------
-- What the probe never does
------------------------------------------------------------

eq("no mutating game call", #G.calls, 0, table.concat(G.calls, ", "))
eq("no AltStableSync write path", #writes, 0, table.concat(writes, ", "))
eq("nothing in chat", #WoW.chat(), 0, table.concat(WoW.chat(), " | "))
check("STEP lines in the probe's own log", logHas("STEP") or logHas("FINISHED"))

-- A Load or Restore that changed nothing never passes.
do
    local mine = DB.rehearsal.records[FIRST]
    local keep = { afterLoad = mine.afterLoad, afterRestore = mine.afterRestore }
    mine.afterLoad = mine.before
    check("a Load that changed nothing fails its check", not NS._checks.differs("first"))
    mine.afterLoad = keep.afterLoad
    mine.afterRestore = keep.afterLoad
    check("a Restore that put nothing back fails its check", not NS._checks.restored("afterRestore")())
    mine.afterRestore = keep.afterRestore
    check("the real records still pass", NS._checks.differs("first") and NS._checks.restored("afterRestore")())
    -- A Load that only created a macro, and a Restore that did nothing: the
    -- macro is an allowed extra, so only the no-op rule catches it.
    local function copy(v)
        if type(v) ~= "table" then return v end
        local o = {}
        for k, x in pairs(v) do o[k] = copy(x) end
        return o
    end
    local keepBefore = mine.before
    local loaded = copy(mine.before)
    loaded.macros[#loaded.macros + 1] = { scope = "character", name = "Zzz", body = "/wave", icon = 134400 }
    mine.afterLoad, mine.afterRestore = loaded, copy(loaded)
    check("a Restore that left the Load's only change in place fails", not NS._checks.restored("afterRestore")())
    mine.before, mine.afterLoad, mine.afterRestore = keepBefore, keep.afterLoad, keep.afterRestore
end

-- A broken Restore: F left unbound fails the check.
do
    local before = DB.rehearsal.records[FIRST].before
    login(FIRST)
    G.keys["F"] = nil
    local c = NS.Compare(before, NS.Record(), NS.Extras(before, DB.rehearsal.records[FIRST].afterLoad))
    check("a Restore that leaves a displaced key unbound is not exact", not c.equal)
end

finish("test_probe")
