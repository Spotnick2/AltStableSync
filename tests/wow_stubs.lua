------------------------------------------------------------
-- wow_stubs.lua - a minimal WoW: Forever API mock for the Lua 5.1 tests
--
-- It models FOREVER (Vanilla content on the Mainline client), not Classic: a
-- removed Classic global is left undefined here, so code that calls one fails
-- in the tests the way it fails in game. When a shape is in question, check
-- docs/forever-api-notes.md (measured) and the API dump in
-- C:\Projects\References (declared). Stub fidelity is part of the review
-- surface, not scaffolding.
--
-- Driven through the global WoW table:
--   WoW.reset()               fresh state (clears SavedVariables, frames, chat)
--   WoW.fire(event, ...)      dispatch an event to every registered frame
--   WoW.chat()                lines printed to DEFAULT_CHAT_FRAME
--   WoW.build                 the build GetBuildInfo() reports
--
-- #3 extends this with action bars, the spellbook, macros, bindings and Edit
-- Mode, shaped by the probe results (#2).
------------------------------------------------------------

WoW = {}

function WoW.reset()
    WoW.frames = {}
    WoW.chatLines = {}
    WoW.build = "70245"
    WoW.now = 1760000000          -- what time() returns; tests move it forward
    WoW.metadata = { AltStableSync = { Version = "dev" } }
    AltStableSync = nil
    AltStableSyncDB, AltStableSyncChar, AltStableSyncLAS = nil, nil, nil
    SlashCmdList = {}
end

function WoW.chat() return WoW.chatLines end

DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg) table.insert(WoW.chatLines, msg) end,
}

function GetBuildInfo()
    return "1.60.1", WoW.build, "Oct  5 2026", 16001
end

-- The client's time(): Unix seconds. Controlled by WoW.now.
function time() return WoW.now end

C_AddOns = {
    GetAddOnMetadata = function(name, field)
        local m = WoW.metadata[name]
        return m and m[field] or nil
    end,
}

-- Frames: just enough for event registration.
function CreateFrame(_, name)
    local f = { events = {}, scripts = {} }
    function f:RegisterEvent(e) self.events[e] = true; return true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:GetScript(k) return self.scripts[k] end
    table.insert(WoW.frames, f)
    if name then _G[name] = f end
    return f
end

function WoW.fire(event, ...)
    for _, f in ipairs(WoW.frames) do
        local h = f.scripts.OnEvent
        if f.events[event] and h then h(f, event, ...) end
    end
end

WoW.reset()
