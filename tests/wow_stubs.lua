------------------------------------------------------------
-- wow_stubs.lua - AltStableSync's own client APIs on top of WowTestKit's mock
--
-- The mechanics (strict globals, secrets, widgets that record their method
-- calls, events checked against the build, timers, hooksecurefunc, print)
-- are WowTestKit's, at the commit and build tests/kit.pin names. This file
-- holds only what the kit leaves to the addon, and the few Methods entries
-- this repo's tests rely on that differ from the core's (each says why).
--
-- It models FOREVER (Vanilla content on the Mainline client), not Classic: a
-- removed Classic global is left undefined here, so code that calls one fails
-- in the tests the way it fails in game. When a shape is in question, check
-- docs/forever-api-notes.md (measured) and the API dump in
-- C:\Projects\WoW\References\Forever\api (declared). Stub fidelity is part of the review
-- surface, not scaffolding.
--
-- Driven through the global WoW table (the kit's, plus):
--   WoW.reset()               fresh state (clears SavedVariables, frames, chat)
--   WoW.fire(event, ...)      dispatch an event to every registered frame
--   WoW.chatLines             lines the addon sent to DEFAULT_CHAT_FRAME
--   WoW.build                 the build GetBuildInfo() reports
--   WoW.now / WoW.clock       what time() / GetTime() return (see below)
--
-- tests/wow_game.lua (action bars, macros, bindings, the pet) and
-- tests/wow_ui.lua (Edit Mode, CVars, chat windows) load after this file.
------------------------------------------------------------

dofile("tests/kit.lua")

local Methods = WoW.Methods

-- State the tests reset (WoW.reset runs each WoW.onReset function).
local KitUIParent = UIParent
table.insert(WoW.onReset, function()
    WoW.chatLines = {}
    WoW.drawn = {}
    WoW.build = "71037"
    WoW.now = 1760000000          -- what time() returns; test_catalog moves it forward
    WoW.clock = 1000              -- what GetTime() returns (seconds of uptime)
    WoW.metadata = { AltStableSync = { Version = "dev" } }
    AltStableSync = nil
    AltStableSyncDB, AltStableSyncChar, AltStableSyncLAS = nil, nil, nil
    SlashCmdList = {}
    UISpecialFrames = {}
    -- A fresh UIParent each time: wow_ui's meter setup replaces it with a plain table.
    UIParent = WoW.newWidget("Frame", nil, "UIParent")
    UIParent._level = 0
end)

DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg) table.insert(WoW.chatLines, msg) end,
}

function GetBuildInfo()
    return "1.60.1", WoW.build, "Oct  5 2026", 16001
end

-- The addon's clock model. The client's time() is Unix seconds (WoW.now);
-- GetTime() is seconds of uptime (WoW.clock), which wow_game.lua's
-- C_Timer.After and WoW.tick advance. The kit's GetTime() and timers run on
-- WoW.now instead, so both are replaced here (and C_Timer / WoW.tick in
-- wow_game.lua): 130 test lines set or read WoW.now and WoW.clock apart.
function time() return WoW.now end
function GetTime() return WoW.clock end

C_AddOns = {
    GetAddOnMetadata = function(name, field)
        local m = WoW.metadata[name]
        return m and m[field] or nil
    end,
}

tinsert = rawget(_G, "tinsert") or table.insert
date = rawget(_G, "date") or os.date

------------------------------------------------------------
-- Widget behaviour this addon's tests rely on, beyond the core's
------------------------------------------------------------

-- Text. An EditBox keeps only its first maxLetters characters (#71: the paste
-- box's limit; the core has no SetMaxLetters). SetText(nil) stores "". WoW.drawn:
-- every text set on anything but an EditBox (#75), as drawn.
local kitSetText = Methods.SetText
local function fit(w, t)
    t = t == nil and "" or tostring(t)
    if w._type == "EditBox" and (w._maxLetters or 0) > 0 and #t > w._maxLetters then t = t:sub(1, w._maxLetters) end
    return t
end
function Methods.SetText(w, t)
    t = fit(w, t)
    if w._type ~= "EditBox" and WoW.drawn then WoW.drawn[#WoW.drawn + 1] = t end
    kitSetText(w, t)
end
function Methods.SetFormattedText(w, fmt, ...) Methods.SetText(w, fmt:format(...)) end
function Methods.SetMaxLetters(w, n) w._maxLetters = n end

-- The player typing or pasting into an EditBox: userInput is true.
function WoW.type(box, t)
    box._text = fit(box, t)
    if box._scripts.OnTextChanged then box._scripts.OnTextChanged(box, true) end
end

-- Focus (the core has none).
function Methods.SetFocus(w) w._focus = true end
function Methods.ClearFocus(w) w._focus = false end
function Methods.HasFocus(w) return w._focus end

-- RegisterForClicks is kept as given (the core's _clicks is SetMouseClickEnabled's).
function Methods.RegisterForClicks(w, ...) w._registeredClicks = { ... } end

-- HookScript is kept apart from the frame's own script: test_minimap and
-- test_taint prove the addon HOOKS the Minimap's OnSizeChanged rather than
-- replacing it (a replaced script on a Blizzard frame is taint). The core
-- folds a hook into _scripts, where it can't be told from SetScript.
function Methods.HookScript(w, name, fn)
    w._hooks = w._hooks or {}
    w._hooks[name] = w._hooks[name] or {}
    table.insert(w._hooks[name], fn)
    return true
end

-- Layout the panel reads (the core has no measuring).
function Methods.GetStringHeight() return 12 end
function Methods.GetVerticalScrollRange() return 0 end
function Methods.GetVerticalScroll() return 0 end

------------------------------------------------------------
-- C_EncodingUtil (declared on 70245; the real round trip is measured in
-- docs/forever-api-notes.md). A STAND-IN: "CBOR" is a sorted Lua literal,
-- "Deflate" a "Z" prefix, "Base64" hex. Each decoder errors on input it
-- didn't make, as the real ones do, so corruption tests exercise our pcalls.
-- Tests prove our framing, checksum and schema handling, not Blizzard's codec.
------------------------------------------------------------
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

-- Globals that may read nil. The addon's own, before they are assigned: the
-- SavedVariables (nil until the client loads them), its global and its
-- preview frame. Client APIs the addon feature-detects (`if C_Timer then`,
-- `pcall(GetCurrentBindingSet)`) and that only wow_game.lua / wow_ui.lua
-- define, or that a test removes on purpose to see the addon without it
-- (C_Timer, issecretvalue, IsMouseButtonDown, C_EncodingUtil...).
Kit.strict({
    AltStableSync = true, AltStableSyncDB = true, AltStableSyncChar = true, AltStableSyncLAS = true,
    AltStableSyncPreview = true, AltStableSyncProbeDB = true,
    EditModeManagerFrame = true, Minimap = true, GameTooltip = true, ChatConfigFrame = true,
    C_CVar = true, C_EditMode = true, C_EncodingUtil = true, C_Timer = true,
    Constants = true, Enum = true, GetCurrentBindingSet = true, IsMouseButtonDown = true,
    issecretvalue = true, LibStub = true, LOCALIZED_CLASS_NAMES_MALE = true, UnitClass = true,
})
