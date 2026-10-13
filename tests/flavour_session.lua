------------------------------------------------------------
-- flavour_session.lua - one client session for test_flavour.lua (#11, A42)
--
--   lua tests/flavour_session.lua seed <lasPath>
--   lua tests/flavour_session.lua case <name> <build> <project> <lasPath>
--
-- A fresh process is a fresh client: LibStub, the library's state, timers,
-- WOW_PROJECT_ID and frames all start new. The session loads the saved store
-- (tests/flavour_fixture.lua, plus the seeded LibAccountSync store), logs in
-- with both addons and the real LibAccountSync, opens the panel and a Load
-- preview without confirming, and checks nothing changed. Its last line is
-- FLAVOUR-SESSION-PASSED <name> only when every check passed.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/libaccountsync.lua")
dofile("tests/flavour_fixture.lua")

local mode = arg[1]
local name, build, project, lasPath
if mode == "seed" then
    name, build, project, lasPath = "seed", "70245", 1, arg[2]
elseif mode == "case" then
    name, build, project, lasPath = arg[2], arg[3], tonumber(arg[4]), arg[5]
else
    error("usage: flavour_session.lua seed <lasPath> | case <name> <build> <project> <lasPath>", 0)
end
assert(lasPath and build and project, "missing arguments")

local G = WoW.game

------------------------------------------------------------
-- The client: one clock for timers and OnUpdate
------------------------------------------------------------

WoW.reset()
WoW.build = build
WOW_PROJECT_ID = project
-- Battle.net "connected, no friends", as in test_link_lib.lua.
function GetCurrentRegion() return 1 end
function UnitName() return "Karuzo" end
function GetRealmName() return "Elegia" end
function UnitFactionGroup() return "Alliance" end
function GetNormalizedRealmName() return "Elegia" end
function BNFeaturesEnabledAndConnected() return true end
function BNConnected() return true end
function BNGetNumFriends() return 0, 0 end
function BNGetInfo() return 1, "Owner#1234", 1 end
function BNSendGameData() end
C_BattleNet = setmetatable({}, { __index = function() return function() return nil end end })
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }
function IsLoggedIn() return true end
function GetServerTime() return WoW.now end
function debugprofilestop() return WoW.clock * 1000 end
function fastrandom(a, b) return math.random(a, b) end
function geterrorhandler() return function(e) error(e, 0) end end
function securecallfunction(fn, ...) return fn(...) end
ChatThrottleLib = { version = 10000, BNSendGameData = function(self, prio, prefix, text, ct, id, q, cb, arg)
    if cb then cb(arg, true, 0) end
end }
-- The minimap and tooltip, for Minimap.lua.
Minimap = NewWidget("Frame", "Minimap")
function Minimap:GetCenter() return 500, 400 end
function Minimap:GetEffectiveScale() return 1 end
function Minimap:GetFrameLevel() return 2 end
GameTooltip = NewWidget("GameTooltip", "GameTooltip")
function GameTooltip:AddLine() end
GetCursorPosition = function() return 500, 600 end

-- wow_game.lua's clock-based C_Timer.After, plus tickers and timers on the
-- same clock (the library uses them).
function C_Timer.NewTimer(s, fn)
    local t = { cancelled = false }
    C_Timer.After(s, function() if not t.cancelled then fn(t) end end)
    function t:Cancel() self.cancelled = true end
    return t
end
function C_Timer.NewTicker(s, fn, iterations)
    local t = { cancelled = false, n = 0 }
    local function step()
        if t.cancelled then return end
        t.n = t.n + 1
        fn(t)
        if not iterations or t.n < iterations then C_Timer.After(s, step) end
    end
    C_Timer.After(s, step)
    function t:Cancel() self.cancelled = true end
    return t
end

-- Advance the clock in 0.1 s steps: due timers, then every shown frame's
-- OnUpdate (Link's tick, the panel's poll). Bounded by `seconds`.
local function pump(seconds)
    for _ = 1, math.floor(seconds * 10 + 0.5) do
        WoW.tick(0.1)
        for _, f in ipairs(WoW.frames) do
            local h = f.scripts.OnUpdate
            if h and f:IsVisible() then h(f, 0.1) end
        end
    end
end

-- The game, held constant across sessions.
G.setup{
    class = "PRIEST", guid = "Player-70-MAIN",
    spells = { { id = 9472, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" } },
    items = { [5512] = 3 },
    macros = { { name = "Shield", body = "/cast Power Word: Shield", char = true } },
    actions = { [1] = { spell = 9472 }, [2] = { spell = 2050 }, [3] = { item = 5512 }, [4] = { macro = "Shield" },
                [5] = { spell = 2050 } },
    keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" },
}
UnitClass = function() return "Priest", "PRIEST" end

------------------------------------------------------------
-- The saved store, as the client loads it at login
------------------------------------------------------------

local function dump(v)
    local t = type(v)
    if t == "string" then return ("%q"):format(v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then error("can't save a " .. t, 0) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = "[" .. dump(k) .. "]=" .. dump(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

local function deepEqual(a, b, path)
    if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then
        if a ~= b then return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
        return true
    end
    for k, v in pairs(a) do
        local ok, why = deepEqual(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. ": added" end
    end
    return true
end

AltStableSyncDB, AltStableSyncChar = FlavourFixture()
local wantDB, wantChar = FlavourFixture()
if mode == "case" then
    local f = assert(io.open(lasPath, "rb"), "no seeded LibAccountSync store at " .. lasPath)
    local text = assert(f:read("*a"))
    f:close()
    AltStableSyncLAS = assert(loadstring("return " .. text))()
    check(name .. ": the seeded LibAccountSync store loaded", type(AltStableSyncLAS) == "table" and next(AltStableSyncLAS) ~= nil)
end

------------------------------------------------------------
-- Login: both addons in TOC order, the real LibAccountSync
------------------------------------------------------------

local function TocFiles(toc)
    local out = {}
    for line in io.lines(toc) do
        line = line:gsub("\r", "")
        if not line:find("^#") and line:find("%.lua$") then out[#out + 1] = line end
    end
    return out
end

LibStub = nil
dofile("Libs/LibStub/LibStub.lua")
local lib = LoadAccountSync("AltStableSync")
for _, f in ipairs(TocFiles("AltStableSync.toc")) do
    if not f:find("^Libs") then
        local dir = f:gsub("\\", "/")
        assert(loadfile(dir))("AltStableSync", {})
    end
end
WoW.fire("ADDON_LOADED", "AltStableSync")
for _, f in ipairs(TocFiles("Plugins/Link/AltStableSyncLink.toc")) do
    assert(loadfile("Plugins/Link/" .. f))("AltStableSyncLink", {})
end
WoW.fire("ADDON_LOADED", "AltStableSyncLink")
WoW.fire("PLAYER_LOGIN")
WoW.fire("PLAYER_ENTERING_WORLD", true, false)
pump(15)

local A = AltStableSync
local Link = A.Link
eq(name .. ": Link started on the real library", Link and Link.state, "on", tostring(Link and Link.why))
check(name .. ": the sync is up", Link and Link.sync ~= nil)
check(name .. ": messages mode (r5)", Link and Link.lib and Link.lib.messages == true)
check(name .. ": the instance comes from the loaded library", lib ~= nil)

if mode == "seed" then
    check("seed: the library made its store", type(AltStableSyncLAS) == "table" and next(AltStableSyncLAS) ~= nil)
    local f = assert(io.open(lasPath, "wb"), "can't write " .. lasPath)
    assert(f:write(dump(AltStableSyncLAS)))
    assert(f:close())
    finishWith("flavour seed", "FLAVOUR-SESSION-PASSED seed")
end

------------------------------------------------------------
-- Use it: the panel and a Load preview, never confirmed
------------------------------------------------------------

-- G.calls has logged every mutating game call since G.setup, so the check
-- below covers the whole login as well as the panel and the preview.
eq(name .. ": no game write during login", #G.calls, 0)
A.Panel.Show()
local m = A.Panel.Model(A.Panel.sel)
local entry
for _, e in pairs(AltStableSyncDB.presets) do if e.name == "Everyday" then entry = e end end
check(name .. ": the loadout is there", entry ~= nil)
local plan = entry and A.Loadout.Plan(entry)
if entry then A.Commands.LoadEntry(entry) end
pump(15)

check(name .. ": not disabled", A.disabled == nil, tostring(A.disabled))
check(name .. ": the panel isn't blocked", m.blocked == nil, tostring(m.blocked))
check(name .. ": ready", m.ready == true)
check(name .. ": a Load plans", plan ~= nil and plan.blocked == nil, tostring(plan and plan.blocked))
check(name .. ": the Load preview is up, unconfirmed", A.Preview.Shown() ~= nil)
eq(name .. ": no game write from login to the preview", #G.calls, 0)
local okDB, whyDB = deepEqual(AltStableSyncDB, wantDB, "DB")
check(name .. ": AltStableSyncDB unchanged", okDB, whyDB)
local okChar, whyChar = deepEqual(AltStableSyncChar, wantChar, "Char")
check(name .. ": AltStableSyncChar unchanged", okChar, whyChar)
check(name .. ": the LibAccountSync store kept", type(AltStableSyncLAS) == "table" and next(AltStableSyncLAS) ~= nil)
-- Chat: nothing but the build warning, off the measured build.
local other = {}
for _, l in ipairs(WoW.chat()) do
    if not l:find("is not the measured build", 1, true) then other[#other + 1] = l end
end
eq(name .. ": nothing else said", table.concat(other, " | "), "")
local warned = table.concat(WoW.chat(), "\n"):find("is not the measured build", 1, true) ~= nil
eq(name .. ": the build warning only off " .. A.MEASURED_ON_BUILD, warned, build ~= A.MEASURED_ON_BUILD)

finishWith("flavour " .. name, "FLAVOUR-SESSION-PASSED " .. name)
