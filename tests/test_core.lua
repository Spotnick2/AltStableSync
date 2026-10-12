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
    eq("fresh: schema", AltStableSyncDB.schema, 8)
    eq("fresh: schema constant", A.SCHEMA, 8)
    check("fresh: presets table", type(AltStableSyncDB.presets) == "table")
    check("fresh: backups table", type(AltStableSyncDB.backups) == "table")
    eq("fresh: no profiles", AltStableSyncDB.profiles, nil)
    eq("fresh: char schema", AltStableSyncChar.schema, 8)
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

-- The scaffold's empty schema-1 DB upgrades: schema 3, `profiles` dropped,
-- everything else kept (the same tables, not copies).
do
    local backups = { ["Player-1-0001"] = { firstSeen = { actions = {} } } }
    local db = { schema = 1, profiles = {}, backups = backups }
    local A = load(db, {})
    check("upgrade: usable", A.disabled == nil, tostring(A.disabled))
    check("upgrade: same DB object", rawequal(AltStableSyncDB, db))
    eq("upgrade: schema 4", db.schema, 8)
    eq("upgrade: profiles dropped", db.profiles, nil)
    check("upgrade: presets added", type(db.presets) == "table" and next(db.presets) == nil)
    check("upgrade: same backups table", db.backups == backups)
    eq("upgrade: empty char gets schema 4", AltStableSyncChar.schema, 8)
end

-- Schema 1 with no `profiles` key at all upgrades too.
do
    local A = load({ schema = 1 }, nil)
    check("upgrade, no profiles key: usable", A.disabled == nil, tostring(A.disabled))
    eq("upgrade, no profiles key: schema 4", AltStableSyncDB.schema, 8)
end

-- A cover as text ("1-12,145-180"), for comparing.
local function R(c)
    local t = {}
    for _, r in ipairs(c or {}) do t[#t + 1] = r[1] .. "-" .. r[2] end
    return table.concat(t, ",")
end

-- Schema-2 data upgrades to 4: every table and value kept, a schema-2
-- `loaded` record is NOT given an `after` (#28), and loadouts get the 1-12
-- cover (#5).
do
    local presets = { ["loadout-abc-1"] = { id = "loadout-abc-1", kind = "loadout" } }
    local loaded = { loadout = { id = "loadout-abc-1", version = "abc:1", baseline = { actions = {} },
                                 result = { skips = {} } } }
    local A = load({ schema = 2, presets = presets, backups = {} },
                   { schema = 2, lastSelected = { ui = "ui-abc-2" }, loaded = loaded })
    check("2->4: usable", A.disabled == nil, tostring(A.disabled))
    eq("2->4: DB stamped", AltStableSyncDB.schema, 8)
    eq("2->4: char stamped", AltStableSyncChar.schema, 8)
    check("2->4: same presets table", AltStableSyncDB.presets == presets)
    eq("2->4: char selection kept", AltStableSyncChar.lastSelected.ui, "ui-abc-2")
    check("2->4: loaded record kept", AltStableSyncChar.loaded == loaded and loaded.loadout.version == "abc:1")
    eq("2->4: no invented comparison", loaded.loadout.after, nil)
    eq("2->4: baseline covers 1-12", R(loaded.loadout.baseline.cover), "1-12")
end

-- 3 -> 4 (#5): every loadout's modules, previous modules and loaded record
-- get the 1-12 cover; anything else is untouched.
do
    local presets = {
        ["loadout-a-1"] = { id = "loadout-a-1", kind = "loadout", modules = { actions = {} },
                            previous = { of = "a:0", modules = { actions = {} } } },
        ["loadout-a-2"] = { id = "loadout-a-2", kind = "loadout", deleted = true },
        ["loadout-a-3"] = { id = "loadout-a-3", kind = "loadout", modules = { cover = { { 1, 180 } } } },
        ["ui-a-4"] = { id = "ui-a-4", kind = "ui", modules = {} },
    }
    local rec = { id = "loadout-a-1", version = "a:1", baseline = { actions = {} }, after = { actions = {} } }
    local A = load({ schema = 3, presets = presets, backups = {} }, { schema = 3, loaded = { loadout = rec } })
    check("3->4: usable", A.disabled == nil, tostring(A.disabled))
    eq("3->4: DB stamped", AltStableSyncDB.schema, 8)
    eq("3->4: modules cover", R(presets["loadout-a-1"].modules.cover), "1-12")
    eq("3->4: previous cover", R(presets["loadout-a-1"].previous.modules.cover), "1-12")
    eq("3->4: tombstone untouched", presets["loadout-a-2"].modules, nil)
    eq("3->4: an existing cover kept", presets["loadout-a-3"].modules.cover[1][2], 180)
    eq("3->4: ui untouched", presets["ui-a-4"].modules.cover, nil)
    eq("3->4: baseline cover", R(rec.baseline.cover), "1-12")
    eq("3->4: after cover", R(rec.after.cover), "1-12")
    -- A DB already at 4 with a character still at 3: only the character upgrades.
    local rec2 = { id = "x", version = "x:1", baseline = {}, after = {} }
    load({ schema = 4, presets = {}, backups = {} }, { schema = 3, loaded = { loadout = rec2 } })
    eq("mixed 4/3: char stamped", AltStableSyncChar.schema, 8)
    eq("mixed 4/3: record cover", R(rec2.after.cover), "1-12")
    -- 4 -> 5 (#46) only stamps the number: a schema-4 loadout without a cover
    -- is damaged and stays so (its operations refuse), never made 1-12.
    local p5 = { ["loadout-b-1"] = { id = "loadout-b-1", kind = "loadout", modules = { actions = {} } } }
    local rec5 = { id = "loadout-b-1", version = "b:1", baseline = { actions = {} }, after = { actions = {} } }
    load({ schema = 4, presets = p5, backups = {} }, { schema = 4, loaded = { loadout = rec5 } })
    eq("4->5: DB stamped", AltStableSyncDB.schema, 8)
    eq("4->5: char stamped", AltStableSyncChar.schema, 8)
    eq("4->5: no cover invented", p5["loadout-b-1"].modules.cover, nil)
    eq("4->5: record no cover invented", rec5.after.cover, nil)
    -- 5 -> 6 (#7) only stamps the number too; a schema-6 guard is kept as is.
    local guard = { before = { ACTIONBUTTON1 = { "1" } }, at = "loading character keybindings" }
    load({ schema = 5, presets = {}, backups = {} }, { schema = 5 })
    eq("5->6: DB stamped", AltStableSyncDB.schema, 8)
    eq("5->6: char stamped", AltStableSyncChar.schema, 8)
    load({ schema = 6, presets = {}, backups = {} }, { schema = 6, bindingSwitch = guard })
    check("6: guard kept", AltStableSyncChar.bindingSwitch == guard and AltStableSync.char.bindingSwitch.before.ACTIONBUTTON1[1] == "1")
    -- 6 -> 7 (#47) only stamps the number: 7 adds the optional pet module.
    local entry = { id = "loadout-x-1", kind = "loadout", class = "HUNTER", category = "general", name = "Six",
                    version = "x:1", modules = { actions = {}, cover = { { 1, 12 } } } }
    load({ schema = 6, presets = { [entry.id] = entry }, backups = {} }, { schema = 6, bindingSwitch = guard })
    eq("6->7: DB stamped", AltStableSyncDB.schema, 8)
    eq("6->7: char stamped", AltStableSyncChar.schema, 8)
    check("6->7: entry kept as is", AltStableSyncDB.presets[entry.id] == entry and entry.modules.pet == nil)
    check("6->7: guard kept", AltStableSyncChar.bindingSwitch == guard)
    -- 7 -> 8 (#6) only stamps the number: 8 adds backups' optional
    -- editedMacros. A schema-7 backup and loaded record are kept as they are.
    local snap = { reason = "load Seven", actions = { [4] = { kind = "macro", name = "Heal", body = "/a", scope = "char" } },
                   keys = {}, createdMacros = {} }
    local backups = { ["Player-70-X"] = { ring = { snap } } }
    local rec = { id = entry.id, version = "x:1", baseline = { actions = {} }, after = { actions = {} } }
    load({ schema = 7, presets = { [entry.id] = entry }, backups = backups }, { schema = 7, loaded = { loadout = rec } })
    eq("7->8: DB stamped", AltStableSyncDB.schema, 8)
    eq("7->8: char stamped", AltStableSyncChar.schema, 8)
    check("7->8: backup kept as is", AltStableSyncDB.backups["Player-70-X"].ring[1] == snap and snap.editedMacros == nil)
    check("7->8: record kept as is", AltStableSyncChar.loaded.loadout == rec)
end

-- The cover helper.
do
    local A = load(nil, nil)
    local C = A.Cover
    check("cover: valid", C.Valid({ { 1, 120 }, { 145, 180 } }))
    check("cover: empty invalid", not C.Valid({}))
    check("cover: overlap invalid", not C.Valid({ { 1, 20 }, { 10, 30 } }))
    check("cover: reversed invalid", not C.Valid({ { 5, 1 } }))
    check("cover: fraction invalid", not C.Valid({ { 1, 1.5 } }))
    check("cover: too large invalid", not C.Valid({ { 1, 5000 } }))
    check("cover: stray key invalid", not C.Valid({ { 1, 12 }, x = 1 }))
    check("cover: zero invalid", not C.Valid({ { 0, 12 } }))
    -- One slot set, one spelling: adjacent ranges must be merged (#44 review).
    check("cover: adjacent ranges invalid", not C.Valid({ { 1, 12 }, { 13, 24 } }))
    check("cover: a gap of one slot valid", C.Valid({ { 1, 12 }, { 14, 24 } }))
    check("cover: Ok needs one", not C.Ok({}) and not C.Ok({ cover = { { 2, 1 } } }) and C.Ok({ cover = { { 1, 12 } } }))
    eq("cover: from set", R(C.FromSet({ [1] = true, [2] = true, [3] = true, [7] = true })), "1-3,7-7")
    eq("cover: empty set", C.FromSet({}), nil)
    check("cover: has", C.Has({ { 1, 3 }, { 7, 9 } }, 8) and not C.Has({ { 1, 3 }, { 7, 9 } }, 5))
end

-- Mixed: the account DB already at 3 (another character upgraded it), this
-- character still at 2.
do
    local A = load({ schema = 3, presets = {}, backups = {} }, { schema = 2, lastSelected = { ui = "u" } })
    check("mixed 3/2: usable", A.disabled == nil, tostring(A.disabled))
    eq("mixed 3/2: char stamped", AltStableSyncChar.schema, 8)
    eq("mixed 3/2: char data kept", AltStableSyncChar.lastSelected.ui, "u")
    local B = load({ schema = 2, presets = {}, backups = {} }, { schema = 3 })
    check("mixed 2/3: usable", B.disabled == nil, tostring(B.disabled))
    eq("mixed 2/3: DB stamped", AltStableSyncDB.schema, 8)
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
                      { schema = 2, lastSelected = { ui = "p9" } }, "schema 99, this build reads 8 - update")
    check("newer schema: said so at load", anyLine("disabled"))
    WoW.chatLines = {}
    A.SlashHandler("status")
    check("newer schema: slash refuses", anyLine("^.*disabled: saved data has schema 99"))
end

-- Unknown schemas that are not "newer" are refused too.
refused("schema 0", { schema = 0, presets = {} }, nil, "schema 0")
refused("schema -1", { schema = -1 }, nil, "schema -1")
refused("schema 1.5", { schema = 1.5 }, nil, "schema 1.5")
refused("schema 9", { schema = 9 }, nil, "schema 9, this build reads 8 - update")
-- #7's guard is never guessed at: damaged, the whole file is refused untouched.
refused("guard a string", { schema = 6, presets = {} }, { schema = 6, bindingSwitch = "x" }, "bindingSwitch is damaged")
refused("guard without before", { schema = 6, presets = {} }, { schema = 6, bindingSwitch = { at = "x" } }, "bindingSwitch is damaged")
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
refused("char schema 9", { schema = 2 }, { schema = 9 }, "character data has schema 9")
-- A newer schema in either table leaves BOTH untouched, the upgradable one too.
refused("char schema 9, DB 3", { schema = 3, presets = {} }, { schema = 9 }, "character data has schema 9")
refused("DB schema 9, char 2", { schema = 9 }, { schema = 2, lastSelected = { ui = "x" } }, "schema 9")
refused("char loaded not a table", { schema = 3 }, { schema = 2, loaded = "x" }, "loaded is a string")
refused("char string schema", { schema = 2 }, { schema = "2" }, 'character data has schema "2" (string)')
refused("upgradable DB, bad char", { schema = 1, profiles = {} }, { stray = true }, "AltStableSyncChar has data")
refused("newer schema, string char", { schema = 99 }, "corrupt", "schema 99")

-- An empty table (a fresh SV file) is a fresh start, not "data with no schema".
do
    local A = load({}, nil)
    check("empty DB: usable", A.disabled == nil)
    eq("empty DB: schema stamped", AltStableSyncDB.schema, 8)
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
    check("status line", anyLine("schema 8, 0 saved setup%(s%)"))
    WoW.chatLines = {}
    A.SlashHandler("nonsense")
    check("help line", anyLine("commands:"))
end

finish("test_core")
