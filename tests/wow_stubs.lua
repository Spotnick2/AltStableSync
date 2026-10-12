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
    WoW.build = "70338"
    WoW.now = 1760000000          -- what time() returns; test_catalog moves it forward
    WoW.clock = 1000              -- what GetTime() returns (seconds of uptime)
    WoW.metadata = { AltStableSync = { Version = "dev" } }
    AltStableSync = nil
    AltStableSyncDB, AltStableSyncChar, AltStableSyncLAS = nil, nil, nil
    SlashCmdList = {}
    UISpecialFrames = {}
    UIParent = NewWidget("Frame", "UIParent")
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

-- Frames: event registration, plus what Preview.lua and Panel.lua (#9) need
-- for their real handlers to run in tests: text, shown and enabled state,
-- checks, focus, and Click(), which only clicks a visible, enabled button as
-- the client does. Any other widget method (layout, fonts, textures) is a
-- no-op returning nil.
local Widget = {}
function Widget:RegisterEvent(e) self.events[e] = true; return true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:SetScript(k, fn) self.scripts[k] = fn end
function Widget:GetScript(k) return self.scripts[k] end
function Widget:Show()
    if self.shown then return end
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Widget:Hide()
    if not self.shown then return end
    self.shown = false
    if self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Widget:IsShown() return self.shown end
function Widget:IsVisible()
    local f = self
    while f do
        if not f.shown then return false end
        f = f.parent
    end
    return true
end
function Widget:SetShown(on) if on then self:Show() else self:Hide() end end
-- An EditBox's SetText fires OnTextChanged, as in the client.
function Widget:SetText(t)
    self.text = t == nil and "" or tostring(t)
    if self.kind == "EditBox" and self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
end
function Widget:GetText() return self.text end
function Widget:SetFormattedText(fmt, ...) self:SetText(fmt:format(...)) end
function Widget:Enable() self.enabled = true end
function Widget:Disable() self.enabled = false end
function Widget:IsEnabled() return self.enabled end
function Widget:SetEnabled(on) self.enabled = on and true or false end
function Widget:SetChecked(c) self.checked = c and true or false end
function Widget:GetChecked() return self.checked end
function Widget:SetFocus() self.focus = true end
function Widget:ClearFocus() self.focus = false end
function Widget:HasFocus() return self.focus end
function Widget:Click(button)
    if not (self.enabled and self:IsVisible()) then return false end
    if self.kind == "CheckButton" then self.checked = not self.checked end
    if self.scripts.OnClick then self.scripts.OnClick(self, button or "LeftButton") end
    return true
end
function Widget:GetParent() return self.parent end
function Widget:GetName() return self.name end
function Widget:CreateFontString() return NewWidget("FontString", nil, self) end
function Widget:CreateTexture() return NewWidget("Texture", nil, self) end
function Widget:GetStringHeight() return 12 end
function Widget:GetVerticalScrollRange() return 0 end
function Widget:GetVerticalScroll() return 0 end
local function noop() end
-- Methods are capitalised; a missing lowercase field (parent, focus...) stays nil.
local WIDGET = { __index = function(_, k)
    if Widget[k] then return Widget[k] end
    if type(k) == "string" and k:match("^%u") then return noop end
end }

function NewWidget(kind, name, parent)
    local f = setmetatable({ kind = kind, name = name, parent = parent, events = {}, scripts = {},
                             shown = true, enabled = true, checked = false, text = "" }, WIDGET)
    return f
end

function CreateFrame(kind, name, parent)
    local f = NewWidget(kind or "Frame", name, parent)
    table.insert(WoW.frames, f)
    if name then _G[name] = f end
    return f
end

tinsert = tinsert or table.insert
date = date or os.date

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
