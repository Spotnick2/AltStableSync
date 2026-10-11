------------------------------------------------------------
-- wow_stubs.lua - a minimal WoW: Forever API mock for the Lua 5.1 tests
--
-- It models FOREVER (Vanilla content on the Mainline client), not Classic: a
-- removed Classic global is left undefined here, so code that calls one fails
-- in the tests the way it fails in game. When a shape is in question, check
-- docs/forever-api-notes.md (measured) and the API dump in
-- C:\Projects\WoW\References (declared). Stub fidelity is part of the review
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
    WoW.build = "70334"
    WoW.now = 1760000000          -- what time() returns; test_catalog moves it forward
    WoW.clock = 1000              -- what GetTime() returns (seconds of uptime)
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

-- The client's GetTime(): seconds of uptime. Controlled by WoW.clock.
function GetTime() return WoW.clock end

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

-- C_EncodingUtil (declared on 70245; the real round trip is measured in
-- docs/forever-api-notes.md). A STAND-IN: "CBOR" is a sorted Lua literal,
-- "Deflate" a "Z" prefix, "Base64" hex. Each decoder errors on input it
-- didn't make, as the real ones do, so corruption tests exercise our pcalls.
-- Tests prove our framing, checksum and schema handling, not Blizzard's codec.
do
    local function ser(v)
        local t = type(v)
        if t == "string" then return ("%q"):format(v) end
        if t == "number" or t == "boolean" then return tostring(v) end
        if t ~= "table" then error("SerializeCBOR: unsupported " .. t) end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) < type(b) end
            return a < b
        end)
        local out = {}
        for _, k in ipairs(keys) do out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    C_EncodingUtil = {
        SerializeCBOR = function(v) return ser(v) end,
        DeserializeCBOR = function(s)
            local fn = loadstring("return " .. s)
            if not fn then error("DeserializeCBOR: malformed") end
            setfenv(fn, {})
            return fn()
        end,
        CompressString = function(s) return "Z" .. s end,
        DecompressString = function(s)
            if s:sub(1, 1) ~= "Z" then error("DecompressString: bad stream") end
            return s:sub(2)
        end,
        EncodeBase64 = function(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end,
        DecodeBase64 = function(s)
            if #s % 2 == 1 or s:find("[^%x]") then error("DecodeBase64: bad input") end
            return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
        end,
    }
end

WoW.reset()
