------------------------------------------------------------
-- Core.lua - AltStableSync namespace, SavedVariables, events, slash command
--
-- SavedVariables (declared in AltStableSync.toc):
--   AltStableSyncDB   account-wide: schema, presets (the catalog, Catalog.lua),
--                     backups, origin
--   AltStableSyncChar per character: schema, last selections, loaded
--                     baselines, onboarding, interrupted operation,
--                     a stopped keybinding switch (#7)
-- The LibAccountSync store (AltStableSyncLAS) belongs to the separate
-- AltStableSyncLink addon (#18), so it is written to its own file and never
-- travels with this one. It is deliberately NOT declared here.
--
-- SavedVariables are read at ADDON_LOADED, never at file scope: the client
-- runs the SV file AFTER the addon's files, overwriting anything assigned here.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local ADDON_NAME = "AltStableSync"

-- The schema this build reads and writes, for both the DB and the per-character
-- table. A NEWER schema came from a newer AltStableSync: refuse it and touch
-- nothing (AGENTS.md safety rule 8). The upgrades this build knows: the
-- empty schema-1 DB the scaffold wrote; 2 -> 3 (3 added the optional `after`
-- and `unavailable` to the per-character `loaded` record, #28; a schema-2
-- record has neither and is never given an invented one); and 3 -> 4 (#5),
-- which stamps `cover = { {1, 12} }` on every loadout's modules, previous
-- modules and loaded record: what the 1-12 builds captured; and 4 -> 5
-- (#46), which only stamps the number: 5 adds the optional `class = true` on
-- spell actions from the class spellbook tabs; and 5 -> 6 (#7), a stamp too:
-- 6 adds the optional per-character `bindingSwitch` guard; and 6 -> 7
-- (#47), a stamp too: 7 adds the optional `pet` module (a pet bar per pet
-- family), backups' `pet` and the loaded record's `after.pet`. There is no
-- migration framework.
local SCHEMA = 7
ASS.SCHEMA = SCHEMA

------------------------------------------------------------
-- Action-slot coverage (#5)
------------------------------------------------------------

-- Which action slots a capture covered: sorted, non-overlapping ranges
-- { {first, last}, ... }. A slot outside an entry's cover was never captured
-- (an older build), which is not the same as captured empty.
local Cover = {}
ASS.Cover = Cover
Cover.LEGACY = { { 1, 12 } }        -- what every build before #5 captured
Cover.MAX = 1000                    -- no action slot id is anywhere near this

function Cover.Valid(c)
    if type(c) ~= "table" or #c == 0 then return false end
    local prev = 0
    for i = 1, #c do
        local r = c[i]
        if type(r) ~= "table" or type(r[1]) ~= "number" or type(r[2]) ~= "number" then return false end
        if r[1] ~= math.floor(r[1]) or r[2] ~= math.floor(r[2]) then return false end
        -- Ascending and canonical: adjacent ranges are merged, so one slot
        -- set has one spelling (Save's no-op check compares it as text).
        if r[1] < 1 or (i > 1 and r[1] <= prev + 1) or r[2] < r[1] or r[2] > Cover.MAX then return false end
        prev = r[2]
    end
    for k in pairs(c) do
        if type(k) ~= "number" or k < 1 or k > #c then return false end
    end
    return true
end

-- Does a loadout's modules table carry a valid cover? After the 3 -> 4
-- upgrade every one does; a missing or malformed one (a hand edit) is never
-- guessed at: the operation that needs it refuses.
function Cover.Ok(modules)
    return type(modules) == "table" and Cover.Valid(modules.cover)
end

function Cover.Has(c, slot)
    for i = 1, #c do
        if slot >= c[i][1] and slot <= c[i][2] then return true end
    end
    return false
end

-- { [slot] = true } -> ranges; nil for an empty set.
function Cover.FromSet(set)
    local slots = {}
    for slot in pairs(set) do slots[#slots + 1] = slot end
    if #slots == 0 then return nil end
    table.sort(slots)
    local out, first, last = {}, slots[1], slots[1]
    for i = 2, #slots do
        if slots[i] == last + 1 then last = slots[i]
        else out[#out + 1] = { first, last }; first, last = slots[i], slots[i] end
    end
    out[#out + 1] = { first, last }
    return out
end

-- Adds every slot of `c` to `set` (and returns it).
function Cover.AddTo(set, c)
    for i = 1, #c do
        for slot = c[i][1], c[i][2] do set[slot] = true end
    end
    return set
end

local function Legacy() return { { Cover.LEGACY[1][1], Cover.LEGACY[1][2] } } end

-- 3 -> 4: a loadout's modules without a cover were captured by a 1-12 build.
local function StampCover(modules)
    if type(modules) == "table" and modules.cover == nil then modules.cover = Legacy() end
end

-- The client build docs/forever-api-notes.md was measured on. A different
-- build says so once at login (see the client-update skill).
local MEASURED_ON_BUILD = "70338"
ASS.MEASURED_ON_BUILD = MEASURED_ON_BUILD

-- The DB fields that must be tables. One list serves both the validation and
-- the defaults, so a new field can't get a default without a type check.
local DB_TABLES = { "presets", "backups" }

local PREFIX = "|cff00ccff[AltStableSync]|r "

local function Print(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg)) end
end
ASS.Print = Print

------------------------------------------------------------
-- SavedVariables
------------------------------------------------------------

-- "schema 3", or `schema "2" (string)`: %q, so a string never reads as a match.
local function SchemaText(schema)
    return type(schema) == "number" and tostring(schema)
        or ("%q (%s)"):format(tostring(schema), type(schema))
end

local function WrongSchema(what, schema)
    return what .. " has schema " .. SchemaText(schema) .. ", this build reads " .. SCHEMA
        .. (type(schema) == "number" and schema > SCHEMA and " - update AltStableSync" or "")
end

-- Why the loaded SavedVariables can't be used, or nil plus what to do when
-- they can ("fresh", "upgrade1", "upgrade", "ok"). Pure: it inspects and never assigns,
-- so a refusal leaves every table exactly as loaded and the client writes them
-- back unchanged. Both tables are judged before either is touched.
local function Validate(db, char)
    local dbAction
    if db == nil or (type(db) == "table" and next(db) == nil) then
        dbAction = "fresh"
    elseif type(db) ~= "table" then
        return "AltStableSyncDB is a " .. type(db) .. ", not a table"
    elseif db.schema == nil then
        -- Only an EMPTY table is a fresh start; data with no schema is foreign.
        return "AltStableSyncDB has data but no schema"
    elseif db.schema == 1 then
        -- The scaffold's schema 1. It never wrote a profile, so only an empty
        -- `profiles` is ours to upgrade; anything else is not ours to guess at.
        if db.profiles ~= nil and (type(db.profiles) ~= "table" or next(db.profiles) ~= nil) then
            return "AltStableSyncDB schema 1 holds profiles this build can't upgrade"
        end
        -- Schema 1 never had presets: any value there (even false) is foreign.
        if db.presets ~= nil then
            return "AltStableSyncDB schema 1 holds presets this build can't upgrade"
        end
        if db.backups ~= nil and type(db.backups) ~= "table" then
            return "AltStableSyncDB.backups is a " .. type(db.backups) .. ", not a table"
        end
        dbAction = "upgrade1"
    elseif db.schema ~= SCHEMA and db.schema ~= 2 and db.schema ~= 3 and db.schema ~= 4 and db.schema ~= 5
        and db.schema ~= 6 then
        return WrongSchema("saved data", db.schema)
    else
        for _, field in ipairs(DB_TABLES) do
            if db[field] ~= nil and type(db[field]) ~= "table" then
                return "AltStableSyncDB." .. field .. " is a " .. type(db[field]) .. ", not a table"
            end
        end
        dbAction = db.schema == SCHEMA and "ok" or "upgrade"
    end

    -- The per-character table: missing or empty is a fresh start (the
    -- scaffold only ever wrote `AltStableSyncChar = {}`, measured on disk);
    -- populated without a schema, or any other schema, is refused - and so,
    -- with it, is the DB.
    local charAction
    if char == nil or (type(char) == "table" and next(char) == nil) then
        charAction = "fresh"
    elseif type(char) ~= "table" then
        return "AltStableSyncChar is a " .. type(char) .. ", not a table"
    elseif char.schema == nil then
        return "AltStableSyncChar has data but no schema"
    elseif char.schema ~= SCHEMA and char.schema ~= 2 and char.schema ~= 3 and char.schema ~= 4 and char.schema ~= 5
        and char.schema ~= 6 then
        return WrongSchema("character data", char.schema)
    elseif char.loaded ~= nil and type(char.loaded) ~= "table" then
        return "AltStableSyncChar.loaded is a " .. type(char.loaded) .. ", not a table"
    elseif char.bindingSwitch ~= nil and (type(char.bindingSwitch) ~= "table" or type(char.bindingSwitch.before) ~= "table") then
        -- #7's guard after a stopped switch: never guessed at.
        return "AltStableSyncChar.bindingSwitch is damaged"
    else
        charAction = char.schema == SCHEMA and "ok" or "upgrade"
    end
    return nil, dbAction, charAction
end

-- A fresh random writer token for this session (docs/DESIGN.md "Data model"):
-- never stored, so a DB copied to two accounts can't mint the same versions.
-- The first part also folds in the clock, so two clients whose math.random
-- happened to start alike would still have to start in the same second with
-- the same uptime millisecond (the client's PRNG seeding is not measured).
local function NewWriterToken()
    local clock = (time and time() or 0) + math.floor(((GetTime and GetTime()) or 0) * 1000)
    local parts = {}
    for i = 1, 4 do parts[i] = math.random(0, 0xfff) end
    parts[1] = (parts[1] + clock) % 0x1000
    for i = 1, 4 do parts[i] = ("%03x"):format(parts[i]) end
    return table.concat(parts)
end

-- Returns true when the DB is usable. Otherwise the addon disables itself for
-- the session (ASS.disabled holds the reason) WITHOUT touching anything:
-- validation runs before the first assignment to either SavedVariable.
local function InitSavedVariables()
    local problem, dbAction, charAction = Validate(AltStableSyncDB, AltStableSyncChar)
    if problem then
        ASS.disabled = problem
        return false
    end

    AltStableSyncDB = AltStableSyncDB or {}
    local db = AltStableSyncDB
    -- Only tables from before schema 4 get the legacy cover: a schema-4
    -- entry without one is damaged, and stays refused (#46).
    if dbAction == "upgrade1" then
        db.profiles = nil          -- empty by validation
    elseif dbAction == "upgrade" and db.schema < 4 and type(db.presets) == "table" then
        for _, e in pairs(db.presets) do
            if type(e) == "table" and e.kind == "loadout" then
                StampCover(e.modules)
                if type(e.previous) == "table" then StampCover(e.previous.modules) end
            end
        end
    end
    db.schema = SCHEMA
    for _, field in ipairs(DB_TABLES) do db[field] = db[field] or {} end

    AltStableSyncChar = AltStableSyncChar or {}
    -- A schema-2 `loaded` record stays without `after`, which Save treats as
    -- "no usable comparison"; its baseline (and a schema-3 `after`) were
    -- captured by a 1-12 build, so they get that cover.
    if charAction == "upgrade" and AltStableSyncChar.schema < 4 then
        local rec = type(AltStableSyncChar.loaded) == "table" and AltStableSyncChar.loaded.loadout
        if type(rec) == "table" then StampCover(rec.baseline); StampCover(rec.after) end
    end
    if charAction == "fresh" or charAction == "upgrade" then AltStableSyncChar.schema = SCHEMA end

    ASS.db = db
    ASS.char = AltStableSyncChar
    ASS.writer, ASS.seq = NewWriterToken(), 0
    return true
end

------------------------------------------------------------
-- Build check
------------------------------------------------------------

local function CheckBuild()
    if not GetBuildInfo then return end
    local _, build = GetBuildInfo()
    if not build or build == MEASURED_ON_BUILD then return end
    Print("client build " .. tostring(build) .. " is not the measured build "
        .. MEASURED_ON_BUILD .. " - sync behaviour on this build is unverified.")
end

------------------------------------------------------------
-- Slash command
------------------------------------------------------------

local function CountKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function SlashHandler(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if ASS.disabled then
        Print("disabled: " .. ASS.disabled)
        return
    end
    if not ASS.db then
        Print("not initialised yet (SavedVariables not loaded)")
        return
    end
    if cmd == "" or cmd == "status" then
        local version = C_AddOns and C_AddOns.GetAddOnMetadata
            and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
        local live = 0
        for _, e in pairs(ASS.db.presets) do
            if type(e) == "table" and not e.deleted then live = live + 1 end
        end
        Print(("version %s, schema %d, %d saved setup(s), %d character backup set(s)"):format(
            tostring(version), ASS.db.schema, live, CountKeys(ASS.db.backups)))
        -- Shown only where it matters: on Character bindings it blocks nothing.
        local guard = ASS.char and ASS.char.bindingSwitch
        local okSet, set = pcall(GetCurrentBindingSet)
        if guard and not (okSet and Enum and Enum.BindingSet and set == Enum.BindingSet.Character) then
            Print("an earlier switch to character keybindings stopped while " .. tostring(guard.at or "starting")
                .. "; if your keys differ from before it, the next switch asks first")
        end
    elseif ASS.Commands and type(ASS.Commands[cmd]) == "function" then
        ASS.Commands[cmd](rest)
    else
        Print("commands: /altsync status | saveas <name> | save [drop] | list | load <id or name> | backups | restore [n or op]" .. " | rename <id or name> <new name> | delete <id or name> | conflicts | resolve <id or name> theirs or mine | link")
    end
end
ASS.SlashHandler = SlashHandler

-- Write a FIELD of SlashCmdList, never the table itself: reassigning the
-- global (even `SlashCmdList = SlashCmdList or {}`) taints it, and secure
-- code that reads it runs tainted - measured on 70235:
-- a /tm raid-marker macro raised ADDON_ACTION_FORBIDDEN SetRaidTarget()
-- blamed on AltStableSync. tests/test_taint.lua guards this.
SLASH_ALTSTABLESYNC1 = "/altsync"
SlashCmdList.ALTSTABLESYNC = SlashHandler

------------------------------------------------------------
-- Events
------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        self:UnregisterEvent("ADDON_LOADED")
        if not InitSavedVariables() then Print("disabled: " .. ASS.disabled) end
    elseif event == "PLAYER_LOGIN" then
        CheckBuild()
    end
end)

-- Test seam: file-local internals for tests/, harmless in game.
ASS._test = {
    Validate = Validate,
    InitSavedVariables = InitSavedVariables,
    CheckBuild = CheckBuild,
    frame = frame,
}
