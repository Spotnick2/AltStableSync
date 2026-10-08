------------------------------------------------------------
-- test_core.lua - SavedVariables init, schema refusal, build check, slash
------------------------------------------------------------

dofile("tests/harness.lua")
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

-- First run: fresh tables at the current schema, and a writer token.
do
    local A = load(nil, nil)
    eq("fresh: schema", AltStableSyncDB.schema, 2)
    eq("fresh: schema constant", A.SCHEMA, 2)
    check("fresh: presets table", type(AltStableSyncDB.presets) == "table")
    check("fresh: backups table", type(AltStableSyncDB.backups) == "table")
    eq("fresh: no profiles", AltStableSyncDB.profiles, nil)
    eq("fresh: char schema", AltStableSyncChar.schema, 2)
    check("fresh: not disabled", A.disabled == nil)
    eq("fresh: LAS store untouched", AltStableSyncLAS, nil)
    check("fresh: writer token is 12 hex", type(A.writer) == "string" and A.writer:match("^%x+$") ~= nil
        and #A.writer == 12, tostring(A.writer))
    eq("fresh: seq starts at 0", A.seq, 0)
end

-- The writer token is per session and never stored: a DB copied to two
-- accounts must not mint the same versions.
do
    local A1 = load(nil, nil); local w1 = A1.writer
    local A2 = load(nil, nil); local w2 = A2.writer
    check("writer: differs between sessions", w1 ~= w2, w1 .. " vs " .. w2)
    for k, v in pairs(AltStableSyncDB) do
        check("writer: not stored in the DB (" .. tostring(k) .. ")", v ~= w2)
    end
end

-- The scaffold's empty schema-1 DB upgrades: schema 2, `profiles` dropped,
-- everything else kept (the same tables, not copies).
do
    local backups = { ["Player-1-0001"] = { firstSeen = { actions = {} } } }
    local db = { schema = 1, profiles = {}, backups = backups }
    local A = load(db, {})
    check("upgrade: usable", A.disabled == nil, tostring(A.disabled))
    check("upgrade: same DB object", rawequal(AltStableSyncDB, db))
    eq("upgrade: schema 2", db.schema, 2)
    eq("upgrade: profiles dropped", db.profiles, nil)
    check("upgrade: presets added", type(db.presets) == "table" and next(db.presets) == nil)
    check("upgrade: same backups table", db.backups == backups)
    eq("upgrade: empty char gets schema 2", AltStableSyncChar.schema, 2)
end

-- Schema 1 with no `profiles` key at all upgrades too.
do
    local A = load({ schema = 1 }, nil)
    check("upgrade, no profiles key: usable", A.disabled == nil, tostring(A.disabled))
    eq("upgrade, no profiles key: schema 2", AltStableSyncDB.schema, 2)
end

-- Existing schema-2 data survives untouched.
do
    local presets = { ["loadout-abc-1"] = { id = "loadout-abc-1", kind = "loadout" } }
    local A = load({ schema = 2, presets = presets, backups = {} },
                   { schema = 2, lastSelected = { ui = "ui-abc-2" } })
    check("existing: usable", A.disabled == nil, tostring(A.disabled))
    check("existing: same presets table", AltStableSyncDB.presets == presets)
    eq("existing: char selection kept", AltStableSyncChar.lastSelected.ui, "ui-abc-2")
end

-- Every refusal leaves ALL THREE SavedVariables exactly as loaded: same
-- object, same keys, nothing added. The client writes them back at logout, so
-- anything changed here is data lost for the build that wrote it.
local function snapshot(v, seen)
    if type(v) ~= "table" then return type(v) .. ":" .. tostring(v) end
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. snapshot(x, seen) end
    table.sort(parts)
    seen[v] = nil
    return "{" .. table.concat(parts, ",") .. "}"
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
                      { schema = 2, lastSelected = { ui = "p9" } }, "schema 99, this build reads 2 - update")
    check("newer schema: said so at load", anyLine("disabled"))
    WoW.chatLines = {}
    A.SlashHandler("status")
    check("newer schema: slash refuses", anyLine("^.*disabled: saved data has schema 99"))
end

-- Unknown schemas that are not "newer" are refused too.
refused("schema 0", { schema = 0, presets = {} }, nil, "schema 0")
refused("schema -1", { schema = -1 }, nil, "schema -1")
refused("schema 1.5", { schema = 1.5 }, nil, "schema 1.5")
refused("schema 3", { schema = 3 }, nil, "schema 3, this build reads 2 - update")
refused("string schema", { schema = "2" }, nil, 'schema "2" (string)')
-- Populated but unschemed: not a fresh start.
refused("no schema, data", { presets = { p1 = {} } }, nil, "has data but no schema")
-- Schema 1 is upgraded only when its `profiles` is empty: this addon never
-- wrote a profile, so a populated or malformed one is not ours to guess at.
refused("schema 1, populated profiles", { schema = 1, profiles = { p1 = { name = "Tank" } } }, nil,
        "schema 1 holds profiles")
refused("schema 1, profiles a number", { schema = 1, profiles = 5 }, nil, "schema 1 holds profiles")
refused("schema 1, backups a string", { schema = 1, profiles = {}, backups = "x" }, nil, "backups is a string")
refused("schema 1, presets false", { schema = 1, profiles = {}, presets = false }, nil, "schema 1 holds presets")
refused("schema 1, presets a string", { schema = 1, profiles = {}, presets = "corrupt" }, nil, "schema 1 holds presets")
refused("schema 1, presets a table", { schema = 1, profiles = {}, presets = {} }, nil, "schema 1 holds presets")
refused("schema 2, presets false", { schema = 2, presets = false }, nil, "presets is a boolean")
-- Malformed roots and fields are refused, never replaced with {}.
refused("DB is a string", "corrupt", nil, "AltStableSyncDB is a string")
refused("presets is a number", { schema = 2, presets = 5 }, nil, "presets is a number")
refused("backups is a string", { schema = 2, presets = {}, backups = "x" }, nil, "backups is a string")
-- The per-character table is judged BEFORE anything is assigned, and its
-- refusal takes the DB with it (untouched).
refused("char is a string", { schema = 2, presets = {}, backups = {} }, "corrupt", "AltStableSyncChar is a string")
refused("char populated, no schema", { schema = 2, presets = {} }, { lastSelected = { ui = "p1" } },
        "AltStableSyncChar has data but no schema")
refused("char schema 3", { schema = 2 }, { schema = 3 }, "character data has schema 3")
refused("char string schema", { schema = 2 }, { schema = "2" }, 'character data has schema "2" (string)')
refused("upgradable DB, bad char", { schema = 1, profiles = {} }, { stray = true }, "AltStableSyncChar has data")
refused("newer schema, string char", { schema = 99 }, "corrupt", "schema 99")

-- An empty table (a fresh SV file) is a fresh start, not "data with no schema".
do
    local A = load({}, nil)
    check("empty DB: usable", A.disabled == nil)
    eq("empty DB: schema stamped", AltStableSyncDB.schema, 2)
end

-- /altsync before our ADDON_LOADED: a clear message, not a nil index.
do
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    local ok, err = pcall(AltStableSync.SlashHandler, "status")
    check("slash before init: no error", ok, tostring(err))
    check("slash before init: says so", anyLine("not initialised"))
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
    check("status line", anyLine("schema 2, 0 saved setup%(s%)"))
    WoW.chatLines = {}
    A.SlashHandler("nonsense")
    check("help line", anyLine("commands:"))
end

finish("test_core")
