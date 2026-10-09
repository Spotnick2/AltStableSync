------------------------------------------------------------
-- test_link_lib.lua - Link.lua against the REAL LibAccountSync (r5)
--
-- The library comes from a checkout (tests/libaccountsync.lua; CI fetches the
-- .pkgmeta pin). This is a wiring check, not a transport test - the library
-- has its own suite, and the two-account rehearsal (#18) is the proof:
--   * New{ messages = true } really yields messages mode and SendTo (r5);
--   * the store is the Link addon's account-wide AltStableSyncLAS;
--   * the host-side calls Link.lua makes exist and don't error with no peer.
-- Battle.net is stubbed as "connected, no friends": no peer is ever found.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/libaccountsync.lua")

-- Just enough Battle.net and timers for the library to start with no peer.
WOW_PROJECT_ID = 18
function GetCurrentRegion() return 1 end
function UnitGUID(unit) return unit == "player" and "Player-1-0000AAAA" or nil end
function UnitName() return "Karuzo" end
function GetRealmName() return "Elegia" end
function UnitFactionGroup() return "Alliance" end
function GetNormalizedRealmName() return "Elegia" end
function BNFeaturesEnabledAndConnected() return true end
function BNConnected() return true end
function BNGetNumFriends() return 0, 0 end
function BNGetInfo() return 1, "Owner#1234", 1 end
local sent = {}
function BNSendGameData(id, prefix, text) sent[#sent + 1] = { id = id, prefix = prefix, text = text } end
C_BattleNet = setmetatable({}, { __index = function() return function() return nil end end })
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }
local timers = {}
C_Timer = {
    After = function(s, fn) timers[#timers + 1] = fn end,
    NewTicker = function(s, fn) timers[#timers + 1] = fn; return { Cancel = function() end } end,
    NewTimer = function(s, fn) timers[#timers + 1] = fn; return { Cancel = function() end } end,
}
function IsLoggedIn() return true end
function GetServerTime() return WoW.now end
function debugprofilestop() return WoW.clock * 1000 end
function fastrandom(a, b) return math.random(a, b) end
function geterrorhandler() return function(e) error(e, 0) end end
function securecallfunction(fn, ...) return fn(...) end
-- A newer-version ChatThrottleLib stand-in, so the vendored copy steps aside
-- (as the library's own tests do); sends complete at once.
ChatThrottleLib = {
    version = 10000,
    BNSendGameData = function(self, prio, prefix, text, chattype, gameAccountID, q, callbackFn, callbackArg)
        sent[#sent + 1] = { id = gameAccountID, prefix = prefix, text = text }
        if callbackFn then callbackFn(callbackArg, true, 0) end
    end,
}

WoW.reset()
UnitClass = function() return "Priest", "PRIEST" end
LibStub = nil
-- The core addon, as the client loads it (its TOC order).
dofile("Libs/LibStub/LibStub.lua")
for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Envelope.lua", "Game.lua", "Backups.lua",
                     "Ready.lua", "Loadout.lua", "Preview.lua", "Commands.lua" }) do
    assert(loadfile(f))("AltStableSync", {})
end
WoW.fire("ADDON_LOADED", "AltStableSync")
assert(AltStableSync.db, "core init failed")

-- The Link addon, as its TOC loads it.
local lib = LoadAccountSync("AltStableSyncLink")
check("library loaded", lib ~= nil)
assert(loadfile("Plugins/Link/Sync.lua"))("AltStableSyncLink", {})
assert(loadfile("Plugins/Link/Link.lua"))("AltStableSyncLink", {})
WoW.fire("ADDON_LOADED", "AltStableSyncLink")
WoW.fire("PLAYER_LOGIN")

local Link = AltStableSync.Link
eq("link started on the real library", Link.state, "on", tostring(Link.why))
check("messages mode really on (r5)", Link.lib and Link.lib.messages == true)
check("SendTo present (r4)", Link.lib and type(Link.lib.SendTo) == "function")
check("store created in the Link addon's table", type(AltStableSyncLAS) == "table")
eq("core DB holds no LAS state", AltStableSyncDB.accountSync, nil)
local leaked = false
for k in pairs(AltStableSyncDB) do if tostring(k):find("key", 1, true) then leaked = true end end
check("core DB holds no key", not leaked)

-- The calls Link.lua makes, with no peer: no error, nothing to anyone.
local ok, err = pcall(function()
    AltStableSync.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Raid" },
        { actions = {}, bindings = {}, macros = {} })
    WoW.clock = WoW.clock + 5
    Link.Tick()
    Link.sync.Refresh()
    AltStableSync.Commands.link("")
    AltStableSync.Commands.link("off")
    AltStableSync.Commands.link("on")
    AltStableSync.Commands.list()
end)
check("link calls run on the real library", ok, tostring(err))
check("status printed", (function()
    for _, l in ipairs(WoW.chat()) do if tostring(l):find("Link: on", 1, true) then return true end end
end)() == true)

finish("test_link_lib")
