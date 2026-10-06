------------------------------------------------------------
-- Core.lua - AltStableSync namespace, SavedVariables, events, slash command
--
-- SavedVariables (declared in AltStableSync.toc):
--   AltStableSyncDB   account-wide: schema, profiles, backups, origin
--   AltStableSyncLAS  account-wide: the LibAccountSync store ONLY (#18). Kept
--                     in its own variable so it can be wiped on a flavour
--                     change (#11) and never travels with a profile.
--   AltStableSyncChar per character: assignment, autoApply, pending
--
-- SavedVariables are read at ADDON_LOADED, never at file scope: the client
-- runs the SV file AFTER the addon's files, overwriting anything assigned here.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local ADDON_NAME = "AltStableSync"

-- The schema this build reads and writes. A DB with a NEWER schema came from a
-- newer AltStableSync: refuse it and touch nothing (AGENTS.md safety rule 8).
-- No migration framework until a real change needs one.
local SCHEMA = 1
ASS.SCHEMA = SCHEMA

-- The client build docs/forever-api-notes.md was measured on. A different
-- build says so once at login (see the client-update skill).
local MEASURED_ON_BUILD = "70235"
ASS.MEASURED_ON_BUILD = MEASURED_ON_BUILD

-- The DB fields that must be tables. One list serves both the validation and
-- the defaults, so a new field can't get a default without a type check.
local DB_TABLES = { "profiles", "backups" }

local PREFIX = "|cff00ccff[AltStableSync]|r "

local function Print(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg)) end
end
ASS.Print = Print

------------------------------------------------------------
-- SavedVariables
------------------------------------------------------------

-- Why the loaded SavedVariables can't be used, or nil when they can. Pure:
-- it inspects and never assigns, so a refusal leaves every table exactly as
-- loaded and the client writes them back unchanged.
local function Validate(db, char)
    if db ~= nil then
        if type(db) ~= "table" then
            return "AltStableSyncDB is a " .. type(db) .. ", not a table"
        end
        -- Only the schema this build knows. A newer one came from a newer
        -- AltStableSync; anything else (0, 0.5, "1") is not ours to guess at.
        -- A populated table with no schema is foreign too: only an EMPTY one
        -- is a fresh start.
        if db.schema == nil then
            if next(db) ~= nil then return "AltStableSyncDB has data but no schema" end
        elseif db.schema ~= SCHEMA then
            -- %q, so a string "1" reads as "1" (string), never as a match.
            local shown = type(db.schema) == "number" and tostring(db.schema)
                or ("%q (%s)"):format(tostring(db.schema), type(db.schema))
            return "saved data has schema " .. shown
                .. ", this build reads " .. SCHEMA
                .. (type(db.schema) == "number" and db.schema > SCHEMA and " - update AltStableSync" or "")
        end
        for _, field in ipairs(DB_TABLES) do
            if db[field] ~= nil and type(db[field]) ~= "table" then
                return "AltStableSyncDB." .. field .. " is a " .. type(db[field]) .. ", not a table"
            end
        end
    end
    if char ~= nil and type(char) ~= "table" then
        return "AltStableSyncChar is a " .. type(char) .. ", not a table"
    end
    return nil
end

-- Returns true when the DB is usable. Otherwise the addon disables itself for
-- the session (ASS.disabled holds the reason) WITHOUT touching anything:
-- validation runs before the first assignment to either SavedVariable.
local function InitSavedVariables()
    local problem = Validate(AltStableSyncDB, AltStableSyncChar)
    if problem then
        ASS.disabled = problem
        return false
    end

    AltStableSyncDB = AltStableSyncDB or {}
    AltStableSyncChar = AltStableSyncChar or {}
    local db = AltStableSyncDB
    db.schema = db.schema or SCHEMA
    for _, field in ipairs(DB_TABLES) do db[field] = db[field] or {} end
    ASS.db = db
    ASS.char = AltStableSyncChar
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
    local cmd = (msg or ""):match("^%s*(%S*)"):lower()
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
        Print(("version %s, schema %d, %d profile(s), %d character backup set(s)"):format(
            tostring(version), ASS.db.schema, CountKeys(ASS.db.profiles), CountKeys(ASS.db.backups)))
    else
        Print("commands: /altsync status")
    end
end
ASS.SlashHandler = SlashHandler

-- Write a FIELD of SlashCmdList, never the table itself: reassigning the
-- global (even `SlashCmdList = SlashCmdList or {}`) taints it, and every
-- secure macro that parses a slash command then runs tainted - measured:
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
