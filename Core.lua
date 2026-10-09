------------------------------------------------------------
-- Core.lua - AltStableSync namespace, SavedVariables, events, slash command
--
-- SavedVariables (declared in AltStableSync.toc):
--   AltStableSyncDB   account-wide: schema, presets (the catalog, Catalog.lua),
--                     backups, origin
--   AltStableSyncChar per character: schema, last selections, loaded
--                     baselines, onboarding, interrupted operation
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
-- nothing (AGENTS.md safety rule 8). The one upgrade this build knows is the
-- empty schema-1 DB the scaffold wrote (docs/DESIGN.md "Data model"); there
-- is no migration framework.
local SCHEMA = 2
ASS.SCHEMA = SCHEMA

-- The client build docs/forever-api-notes.md was measured on. A different
-- build says so once at login (see the client-update skill).
local MEASURED_ON_BUILD = "70245"
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
-- they can ("fresh", "upgrade1", "ok"). Pure: it inspects and never assigns,
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
    elseif db.schema ~= SCHEMA then
        return WrongSchema("saved data", db.schema)
    else
        for _, field in ipairs(DB_TABLES) do
            if db[field] ~= nil and type(db[field]) ~= "table" then
                return "AltStableSyncDB." .. field .. " is a " .. type(db[field]) .. ", not a table"
            end
        end
        dbAction = "ok"
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
    elseif char.schema ~= SCHEMA then
        return WrongSchema("character data", char.schema)
    else
        charAction = "ok"
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
    if dbAction == "upgrade1" then
        db.profiles = nil          -- empty by validation
    end
    db.schema = SCHEMA
    for _, field in ipairs(DB_TABLES) do db[field] = db[field] or {} end

    AltStableSyncChar = AltStableSyncChar or {}
    if charAction == "fresh" then AltStableSyncChar.schema = SCHEMA end

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
    elseif ASS.Commands and type(ASS.Commands[cmd]) == "function" then
        ASS.Commands[cmd](rest)
    else
        Print("commands: /altsync status | saveas <name> | list | load <id or name> | backups | restore [n or op]" .. " | rename <id or name> <new name> | delete <id or name> | conflicts | resolve <id or name> theirs or mine | link")
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
