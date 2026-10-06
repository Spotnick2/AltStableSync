------------------------------------------------------------
-- test_core.lua - SavedVariables init, schema refusal, build check, slash
------------------------------------------------------------

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end
local function anyLine(pattern)
    for _, l in ipairs(WoW.chat()) do if l:find(pattern) then return true end end
    return false
end

dofile("tests/wow_stubs.lua")

-- Load the addon the way the client does: files first, then the SV file runs,
-- then ADDON_LOADED.
local function load(svDB, svChar)
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    AltStableSyncDB, AltStableSyncChar = svDB, svChar
    WoW.fire("ADDON_LOADED", "AltStableSync")
    return AltStableSync
end

-- First run: fresh tables at the current schema.
do
    local A = load(nil, nil)
    eq("fresh: schema", AltStableSyncDB.schema, A.SCHEMA)
    check("fresh: profiles table", type(AltStableSyncDB.profiles) == "table")
    check("fresh: backups table", type(AltStableSyncDB.backups) == "table")
    check("fresh: char table", type(AltStableSyncChar) == "table")
    check("fresh: not disabled", A.disabled == nil)
    eq("fresh: LAS store untouched", AltStableSyncLAS, nil)
end

-- Existing data survives untouched.
do
    local profiles = { p1 = { class = "WARRIOR", name = "Tank" } }
    local A = load({ schema = 1, profiles = profiles, backups = {} }, { profileId = "p1" })
    check("existing: same profiles table", AltStableSyncDB.profiles == profiles)
    eq("existing: char assignment", AltStableSyncChar.profileId, "p1")
    check("existing: not disabled", A.disabled == nil)
end

-- Every refusal leaves ALL THREE SavedVariables exactly as loaded: same
-- object, same keys, nothing added. The client writes them back at logout, so
-- anything changed here is data lost for the build that wrote it.
local function snapshot(v)
    if type(v) ~= "table" then return v end
    local keys = {}
    for k, x in pairs(v) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(x) end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function refused(name, db, char, wantReason)
    local las = { key = "household" }
    local dbBefore, charBefore, lasBefore = snapshot(db), snapshot(char), snapshot(las)
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    AltStableSyncDB, AltStableSyncChar, AltStableSyncLAS = db, char, las
    WoW.fire("ADDON_LOADED", "AltStableSync")
    local A = AltStableSync
    check(name .. ": disabled", A.disabled ~= nil)
    if wantReason then
        check(name .. ": reason", A.disabled and A.disabled:find(wantReason, 1, true) ~= nil,
              "got " .. tostring(A.disabled))
    end
    check(name .. ": DB same object", rawequal(AltStableSyncDB, db))
    eq(name .. ": DB unchanged", snapshot(AltStableSyncDB), dbBefore)
    check(name .. ": char same object", rawequal(AltStableSyncChar, char))
    eq(name .. ": char unchanged", snapshot(AltStableSyncChar), charBefore)
    eq(name .. ": LAS unchanged", snapshot(AltStableSyncLAS), lasBefore)
    check(name .. ": no db handle", A.db == nil)
    return A
end

-- A newer schema: refused, with the update hint, and the slash command says so.
do
    local A = refused("newer schema", { schema = 99, somethingNew = { x = 1 } },
                      { profileId = "p9" }, "schema 99, this build reads 1 - update")
    check("newer schema: said so at load", anyLine("disabled"))
    WoW.chatLines = {}
    A.SlashHandler("status")
    check("newer schema: slash refuses", anyLine("^.*disabled: saved data has schema 99"))
end

-- Unknown schemas that are not "newer" are refused too.
refused("schema 0", { schema = 0, profiles = {} }, nil, "schema 0")
refused("schema -1", { schema = -1 }, nil, "schema -1")
refused("schema 0.5", { schema = 0.5 }, nil, "schema 0.5")
refused("string schema", { schema = "1" }, nil, "schema 1")
-- Populated but unschemed: not a fresh start.
refused("no schema, data", { profiles = { p1 = {} } }, nil, "has data but no schema")
-- Malformed roots and fields are refused, never replaced with {}.
refused("DB is a string", "corrupt", nil, "AltStableSyncDB is a string")
refused("profiles is a number", { schema = 1, profiles = 5 }, nil, "profiles is a number")
refused("backups is a string", { schema = 1, profiles = {}, backups = "x" }, nil, "backups is a string")
-- The per-character table is checked BEFORE anything is assigned.
refused("char is a string", { schema = 1, profiles = {}, backups = {} }, "corrupt", "AltStableSyncChar is a string")
refused("newer schema, string char", { schema = 99 }, "corrupt", "schema 99")

-- An empty table (a fresh SV file) is a fresh start, not "data with no schema".
do
    local A = load({}, nil)
    check("empty DB: usable", A.disabled == nil)
    eq("empty DB: schema stamped", AltStableSyncDB.schema, 1)
end

-- ADDON_LOADED for another addon does nothing.
do
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    WoW.fire("ADDON_LOADED", "SomethingElse")
    eq("other addon: no init", AltStableSyncDB, nil)
end

-- Build check: silent on the measured build, warns once on another.
do
    load(nil, nil)
    WoW.fire("PLAYER_LOGIN")
    check("measured build: silent", not anyLine("not the measured build"))
    load(nil, nil)
    WoW.build = "99999"
    WoW.fire("PLAYER_LOGIN")
    check("other build: warns", anyLine("99999 is not the measured build"))
end

-- Slash command.
do
    local A = load(nil, nil)
    check("slash registered", SlashCmdList.ALTSTABLESYNC == A.SlashHandler)
    eq("slash name", SLASH_ALTSTABLESYNC1, "/altsync")
    WoW.chatLines = {}
    A.SlashHandler("")
    check("status line", anyLine("schema 1, 0 profile%(s%)"))
    WoW.chatLines = {}
    A.SlashHandler("nonsense")
    check("help line", anyLine("commands:"))
end

print(("test_core: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
