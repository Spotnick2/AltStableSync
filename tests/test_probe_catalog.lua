------------------------------------------------------------
-- test_probe_catalog.lua - AltStableSyncProbe's catalog procedures (#98)
--
-- `/fp steps sync catalog` (account A) and `catalog2` (account B) driven end
-- to end through the host, one after the other in one process: the catalog
-- the probe reads is changed by hand between steps, as the owner's clicks
-- and the other account's sync would change it. The probe only reads; its
-- checks pass on the expected states and fail on the broken ones below.
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
            print("test_probe_catalog: SKIPPED (no ForeverProbe checkout; probe tests run locally)")
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

-- AltStableSync as the probe sees it: read paths only, every write a trap.
local writes = {}
local function trap(name) return function() writes[#writes + 1] = name; error("write path " .. name, 2) end end
local peers = {}
local status = {}
AltStableSync = {
    SCHEMA = 12,
    Ready = { IsReady = function() return true end },
    Backups = { List = function() return {}, nil end, Pin = trap("Backups.Pin") },
    Catalog = { Create = trap("Catalog.Create"), Replace = trap("Catalog.Replace"), Upsert = trap("Catalog.Upsert"),
                Resolve = trap("Catalog.Resolve") },
    Loadout = { Load = trap("Loadout.Load"), Save = trap("Loadout.Save") },
    UISetup = { Apply = trap("UISetup.Apply"), Save = trap("UISetup.Save") },
    Link = { state = "on", sync = { Peers = function() return peers end, Refresh = trap("Link.sync.Refresh") },
             EntryStatus = function(e) return status[e.id] end },
}
AltStableSyncDB = { presets = {} }
AltStableSyncChar = {}
local P = AltStableSyncDB.presets

G.setup{ guid = "Player-70-CATA", class = "PRIEST", spells = { { id = 2061, name = "Flash Heal" } } }
UI.setup()

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
local function rec(proc) return ForeverProbeDB.steps.records["AltStableSyncProbe/" .. proc] end
local function result(proc, i) return rec(proc).results[i] end
local function pass(proc, i, what) eq(what .. " passes", result(proc, i).check, "PASS", result(proc, i).checkDetail) end
local function fail(proc, i, what) check(what .. " fails", result(proc, i).check == "FAIL", result(proc, i).checkDetail) end

local function entry(id, v, name, extra)
    local e = { id = id, version = v, kind = "loadout", class = "PRIEST", category = "holy", name = name,
                modules = { cover = { { 1, 12 } }, actions = { [1] = { kind = "spell", id = 2061 } } } }
    for k, x in pairs(extra or {}) do e[k] = x end
    P[id] = e
    return e
end
local ID = "loadout-aaaaaaaaaaaa-1"

------------------------------------------------------------
-- Account A
------------------------------------------------------------

local CA = NS.CAT.A
fp("steps sync catalog")
check("/fp steps sync catalog starts it", rec("catalog") and rec("catalog").status == "active")
S.Run()                                                -- 1 Start
check("the run is set up", DB.catalog and DB.catalog.A and DB.catalog.A.records)
S.Next()                                               -- 2 the other client
-- 3: no peer heard yet: the check fails, and a retake after it answers passes.
S.Run()
fail("catalog", 3, "start with no peer heard")
peers[1] = { label = "Kaleid-Elegia", heard = true }
S.Back(); S.Run()
pass("catalog", 3, "start once the other account is heard")

entry(ID, "aaaaaaaaaaaa:1", "SyncTest")                -- 4: Save As here
status[ID] = "pending"
S.Run()
pass("catalog", 4, "the saved entry found")
status[ID] = "confirmed"                               -- 5: B refreshed
S.Run()
pass("catalog", 5, "confirmed by the other account")

-- 6: renamed on both offline: our SyncA and B's version as a copy.
P[ID].name, P[ID].version = "SyncA", "aaaaaaaaaaaa:2"
entry(ID .. "~bbbbbbbbbbbb:1", "bbbbbbbbbbbb:1", "SyncB (from Kaleid-Elegia)", { conflict = { of = ID, from = "Kaleid-Elegia" } })
S.Run()
pass("catalog", 6, "one conflict copy each side")
-- 7: resolved here: the copy retired, the root moved on.
P[ID .. "~bbbbbbbbbbbb:1"].deleted, P[ID .. "~bbbbbbbbbbbb:1"].modules = true, nil
P[ID].version = "aaaaaaaaaaaa:3"
S.Run()
pass("catalog", 7, "resolved, no copy left")
S.Next()                                               -- 8 share
-- 9: final, with an entry still pending: fails; after B's refresh, passes.
entry("loadout-bbbbbbbbbbbb-2", "bbbbbbbbbbbb:2", "Imported")
status["loadout-bbbbbbbbbbbb-2"] = "pending"
S.Run(); shoot()                                       -- a screenshot step waits for its shot
fail("catalog", 9, "final with an entry still pending")
status["loadout-bbbbbbbbbbbb-2"] = "confirmed"
S.Back(); S.Run(); shoot()
pass("catalog", 9, "final once everything is confirmed")
local finalA = DB.catalog.A.records.final.digest

-- 10: both clients exit fully. A local `previous` is local: the digest
-- leaves it out, so a Save's undo record on one account doesn't count.
FP.run = FP.run + 1
WoW.relaunch()
P[ID].previous = { of = P[ID].version, modules = {} }
S.Resume()
eq("back at the exit question", rec("catalog").at, CA.exit)
S.Answer(true)                                         -- 11
S.Run()                                                -- 12 afterExit
pass("catalog", 12, "the catalog survived the exit")
eq("the digest ignores `previous`", DB.catalog.A.records.afterExit.digest, finalA)
FP.run = FP.run + 1
S.Resume()                                             -- 13 /reload
eq("A finished", rec("catalog").status, "done")

------------------------------------------------------------
-- Account B (the same process: its own records)
------------------------------------------------------------

for id in pairs(P) do P[id] = nil end
for id in pairs(status) do status[id] = nil end
AltStableSync.writer = "bbbbbbbbbbbb"                  -- this client's session token: B mints bbbbbbbbbbbb:n
fp("steps sync catalog2")
S.Run()                                                -- 1 Start
S.Next()                                               -- 2 /altsync link
S.Run()                                                -- 3 start
pass("catalog2", 3, "B linked")
entry(ID, "aaaaaaaaaaaa:1", "SyncTest")
S.Run()                                                -- 4 received
pass("catalog2", 4, "B received the entry")
S.Next()                                               -- 5 refresh
P[ID].name, P[ID].version = "SyncB", "bbbbbbbbbbbb:1"
entry(ID .. "~aaaaaaaaaaaa:2", "aaaaaaaaaaaa:2", "SyncA (from Karuzo-Elegia)", { conflict = { of = ID, from = "Karuzo-Elegia" } })
S.Run()                                                -- 6 diverged
pass("catalog2", 6, "B holds one copy")
P[ID].name, P[ID].version = "SyncA", "aaaaaaaaaaaa:3"
P[ID .. "~aaaaaaaaaaaa:2"].deleted, P[ID .. "~aaaaaaaaaaaa:2"].modules = true, nil
S.Run()                                                -- 7 resolved
pass("catalog2", 7, "B fast-forwarded to the resolution")
S.Answer(true)                                         -- 8 imported?
entry("loadout-bbbbbbbbbbbb-2", "bbbbbbbbbbbb:2", "Imported")
S.Run()                                                -- 9 imported
pass("catalog2", 9, "one new loadout imported")

-- 10-11: a Save that keeps what this character can't use.
AltStableSyncChar.loaded = { loadout = { id = ID, version = "aaaaaaaaaaaa:3", unavailable = { [5] = "not learned" } } }
P[ID].modules.actions[5] = { kind = "spell", id = 2060, name = "Greater Heal", policy = "highest", class = true }
S.Run()                                                -- 10 keptBefore
pass("catalog2", 10, "the load left a slot it couldn't fill")
P[ID].version = "bbbbbbbbbbbb:3"                       -- the Save: slot 1 edited, slot 5 kept
P[ID].modules.actions[1] = { kind = "spell", id = 2050 }
S.Run()                                                -- 11 keptAfter
pass("catalog2", 11, "the Save kept the slot it couldn't fill")

-- 12-14: a UI Save over a hidden meter window 2 keeps the saved window.
local UIID = "ui-aaaaaaaaaaaa-5"
P[UIID] = { id = UIID, version = "aaaaaaaaaaaa:5", kind = "ui", name = "My UI",
            modules = { damageMeter = { windows = { { meterType = 0, sessionType = 1, locked = true },
                                                    { meterType = 0, sessionType = 1, locked = true } } } } }
AltStableSyncChar.loaded.ui = { id = UIID, version = "aaaaaaaaaaaa:5" }
S.Run()                                                -- 12 meterBefore
S.Answer(true)                                         -- 13 the preview said so
P[UIID].version = "bbbbbbbbbbbb:4"                     -- saved, window 2 as it was
S.Run()                                                -- 14 meterAfter
pass("catalog2", 14, "the saved window 2 kept")

for _, id in ipairs({ ID, "loadout-bbbbbbbbbbbb-2", UIID }) do status[id] = "confirmed" end   -- A took them all
S.Run(); shoot()                                       -- 15 final
pass("catalog2", 15, "B settled")
FP.run = FP.run + 1
WoW.relaunch()
S.Resume()
S.Answer(true)                                         -- 17
S.Run()                                                -- 18 afterExit
pass("catalog2", 18, "B's catalog survived the exit")
FP.run = FP.run + 1
S.Resume()
eq("B finished", rec("catalog2").status, "done")
eq("three screenshots (A's final twice, B's once)", shots, 3)

------------------------------------------------------------
-- What the probe never does, and what the checks refuse
------------------------------------------------------------

eq("no mutating game call", #G.calls, 0, table.concat(G.calls, ", "))
eq("no AltStableSync write path", #writes, 0, table.concat(writes, ", "))
eq("nothing in chat", #WoW.chat(), 0, table.concat(WoW.chat(), " | "))
eq("no error", #errors, 0, table.concat(errors, " | "))

do
    local C = NS._catalog
    local R = DB.catalog.B.records
    local keep = { keptAfter = R.keptAfter, meterAfter = R.meterAfter, afterExit = R.afterExit, imported = R.imported }
    local function copy(v)
        if type(v) ~= "table" then return v end
        local o = {}
        for k, x in pairs(v) do o[k] = copy(x) end
        return o
    end
    -- A Save that replaced the kept slot fails.
    local bad = copy(R.keptAfter); bad.loadout.actions[5] = "{changed}"
    R.keptAfter = bad
    check("a Save that dropped a kept slot fails", not C.keptAfter())
    -- No Save at all (version unchanged) fails.
    bad = copy(keep.keptAfter); bad.loadout.entryVersion = R.keptBefore.loadout.entryVersion
    R.keptAfter = bad
    check("no Save since the load fails", not C.keptAfter())
    -- Codex on PR #99: a version received by sync is not this client's Save.
    bad = copy(keep.keptAfter); bad.loadout.entryVersion = "aaaaaaaaaaaa:9"
    R.keptAfter = bad
    check("a received version instead of a Save here fails", not C.keptAfter())
    -- A Save with no button change proves nothing about the merge.
    bad = copy(keep.keptAfter); bad.loadout.actions[1] = R.keptBefore.loadout.actions[1]
    R.keptAfter = bad
    check("a Save without a button change fails", not C.keptAfter())
    R.keptAfter = keep.keptAfter
    -- A UI Save that wrote over window 2 fails.
    bad = copy(R.meterAfter); bad.ui.meter2 = "{[\"locked\"]=false}"
    R.meterAfter = bad
    check("a Save that changed window 2 fails", not C.meterKept())
    -- Codex on PR #99: a cancelled Save (version unchanged) fails, and so
    -- does a version received from the other account.
    bad = copy(keep.meterAfter); bad.ui.entryVersion = R.meterBefore.ui.entryVersion
    R.meterAfter = bad
    check("a cancelled UI Save fails", not C.meterKept())
    bad = copy(keep.meterAfter); bad.ui.entryVersion = "aaaaaaaaaaaa:9"
    R.meterAfter = bad
    check("a received UI version fails", not C.meterKept())
    R.meterAfter = keep.meterAfter
    -- Codex on PR #99: the import must be the shared content, made here.
    local newId = "loadout-bbbbbbbbbbbb-2"
    bad = copy(keep.imported); bad.entries[newId].md = "00000000"
    R.imported = bad
    check("an import of other content fails", not C.imported())
    bad = copy(keep.imported); bad.entries[newId].v = "aaaaaaaaaaaa:7"
    R.imported = bad
    check("a loadout received, not imported here, fails", not C.imported())
    bad = copy(keep.imported); bad.entries["loadout-cccccccccccc-1"] = copy(bad.entries[newId])
    R.imported = bad
    check("two new loadouts fail", not C.imported())
    R.imported = keep.imported
    check("the real records pass", C.imported() and C.keptAfter() and C.meterKept())
    -- A catalog that changed across the exit fails.
    bad = copy(R.afterExit); bad.digest = "00000000"
    R.afterExit = bad
    check("a catalog changed by the exit fails", not C.survived("B")())
    R.afterExit = keep.afterExit
    -- The digest: equal content, equal digest; one changed field, another.
    local x = { a = { 1, "b" }, previous = { 2 } }
    eq("canonical text leaves out previous when asked", C.canon(x, true), C.canon({ a = { 1, "b" } }))
    check("one field changed changes the digest", C.digest(C.canon({ a = 1 })) ~= C.digest(C.canon({ a = 2 })))
end

finish("test_probe_catalog")
