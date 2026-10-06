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

-- A newer schema is refused, and the tables are left exactly as loaded.
do
    local db = { schema = 99, somethingNew = { x = 1 } }
    local A = load(db, nil)
    check("newer schema: disabled", A.disabled ~= nil)
    check("newer schema: same table", AltStableSyncDB == db)
    eq("newer schema: no profiles added", db.profiles, nil)
    eq("newer schema: schema kept", db.schema, 99)
    check("newer schema: says so", anyLine("disabled"))
    A.SlashHandler("status")
    check("newer schema: slash refuses", anyLine("disabled: saved data has schema 99"))
end

-- A non-numeric schema is treated as foreign too.
do
    local A = load({ schema = "1" }, nil)
    check("string schema: disabled", A.disabled ~= nil)
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
    A.SlashHandler("")
    check("status line", anyLine("schema 1, 0 profile%(s%)"))
    A.SlashHandler("nonsense")
    check("help line", anyLine("commands:"))
end

print(("test_core: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
