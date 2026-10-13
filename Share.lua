------------------------------------------------------------
-- Share.lua - a loadout as a text string, and back (#71)
--
-- Share shows a loadout's string; Import validates a pasted one and, after
-- a preview, saves it as a NEW catalog entry (as Save As does). Neither
-- reads or writes game state: Load stays a separate step with its own
-- preview. A string may come from anyone, so every record has a field
-- allowlist and every collection a bound; anything else refuses the whole
-- string, never a part of it. Share checks its own output the same way, so
-- every string it shows imports on this build.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Share = {}
ASS.Share = Share

local INT_MAX = 2147483647
local NAME_MAX = 240         -- bytes; the Save As box takes 60 letters
local MACRO_BODY_MAX = 256   -- bytes, raw: 255 plus the newline the server appends (measured)
local KEYS_MAX = 16          -- keys on one command
local FAMILIES_MAX, RANGES_MAX = 64, 64
local PET_SLOTS = 10
local MODULE_KEYS = { actions = true, bindings = true, macros = true, cover = true, pet = true }
Share.KEYS_MAX = KEYS_MAX

------------------------------------------------------------
-- Validation
------------------------------------------------------------

local function Int(n) return type(n) == "number" and n >= 1 and n <= INT_MAX and n == math.floor(n) end

-- A string up to `max` bytes. `line`: one line of text (no control
-- character at all); otherwise newlines and tabs are allowed. Never a NUL.
local function Str(s, max, line, allowEmpty)
    if type(s) ~= "string" or #s > max or (s == "" and not allowEmpty) then return false end
    if line then return not s:find("%c") end
    return not s:find("[%z\1-\8\11\12\14-\31\127]")
end

-- Only the fields in `allowed` (a set of names).
local function Only(t, allowed)
    for k in pairs(t) do
        if not allowed[k] then return false end
    end
    return true
end

-- A dense list 1..n of up to `max` entries, each passing `ok`.
local function List(t, max, ok)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if not Int(k) then return false end
        n = n + 1
    end
    if n > max then return false end
    for i = 1, n do
        if t[i] == nil or not ok(t[i]) then return false end
    end
    return true
end

local SPELL = { kind = true, id = true, name = true, policy = true, class = true }
local ITEM = { kind = true, id = true }
local MACRO = { kind = true, name = true, body = true, scope = true }
local UNSUPPORTED = { kind = true, what = true }

local function GoodAction(a, macros)
    if type(a) ~= "table" then return false end
    if a.kind == "spell" then
        return Only(a, SPELL) and Int(a.id) and (a.name == nil or Str(a.name, 100, true))
            and (a.policy == nil or a.policy == "exact" or a.policy == "highest") and (a.class == nil or a.class == true)
    elseif a.kind == "item" then
        return Only(a, ITEM) and Int(a.id)
    elseif a.kind == "macro" then
        if not (Only(a, MACRO) and Str(a.name, 16, true) and Str(a.body, MACRO_BODY_MAX, false, true)) then return false end
        if a.scope == "char" then return macros[a.name] ~= nil end
        return a.scope == "account"
    elseif a.kind == "unsupported" then
        return Only(a, UNSUPPORTED) and (a.what == nil or Str(a.what, 64, true))
    end
    return false
end

local DEF = { body = true, icon = true }
local function GoodMacros(m)
    if type(m) ~= "table" then return false end
    local n = 0
    for name, def in pairs(m) do
        n = n + 1
        if n > ASS.Game.MAX_CHAR_MACROS then return false end
        if not Str(name, 16, true) or type(def) ~= "table" or not Only(def, DEF) then return false end
        if not Str(def.body, MACRO_BODY_MAX, false, true) then return false end
        if def.icon ~= nil and not Int(def.icon) and not Str(def.icon, 256, true) then return false end
    end
    return true
end

local function GoodBindings(b)
    if type(b) ~= "table" then return false end
    local managed = {}
    for _, cmd in ipairs(ASS.Game.COMMANDS) do managed[cmd] = true end
    for cmd, keys in pairs(b) do
        if not managed[cmd] then return false end
        if not List(keys, KEYS_MAX, function(k) return Str(k, 32, true) end) then return false end
    end
    return true
end

local LAYOUT = { family = true, locale = true, slots = true }
local TOKEN, PETSPELL = { kind = true, token = true }, { kind = true, id = true, name = true }
local function GoodPetSlot(s)
    if s == false then return true end
    if type(s) ~= "table" then return false end
    if s.kind == "token" then return Only(s, TOKEN) and Str(s.token, 32, true) end
    if s.kind == "spell" then return Only(s, PETSPELL) and Int(s.id) and Str(s.name, 100, true) end
    return false
end

local function GoodPet(p)
    if type(p) ~= "table" then return false end
    local n = 0
    for fam, layout in pairs(p) do
        n = n + 1
        if n > FAMILIES_MAX or not Int(fam) or type(layout) ~= "table" or not Only(layout, LAYOUT) then return false end
        if not Str(layout.family, 32, true) then return false end
        if layout.locale ~= nil and not Str(layout.locale, 32, true) then return false end
        if type(layout.slots) ~= "table" then return false end
        for k in pairs(layout.slots) do
            if not (Int(k) and k <= PET_SLOTS) then return false end
        end
        for i = 1, PET_SLOTS do
            if layout.slots[i] == nil or not GoodPetSlot(layout.slots[i]) then return false end
        end
        if not ASS.Pet.Valid(layout) then return false end
    end
    return true
end

local function GoodCover(c)
    if not ASS.Cover.Valid(c) or #c > RANGES_MAX then return false end
    for _, r in ipairs(c) do
        for k in pairs(r) do
            if k ~= 1 and k ~= 2 then return false end
        end
    end
    return true
end

local SHARE = { kind = true, class = true, category = true, name = true, modules = true }

-- Whether `x` is a share this build can import: true, or false.
function Share.Valid(x)
    if type(x) ~= "table" or not Only(x, SHARE) or x.kind ~= "loadout" then return false end
    if not (Str(x.class, 32, true) and Str(x.category, 32, true) and Str(x.name, NAME_MAX, true)) then return false end
    local m = x.modules
    if type(m) ~= "table" or not Only(m, MODULE_KEYS) or not GoodCover(m.cover) then return false end
    local macros = m.macros or {}
    if m.macros ~= nil and not GoodMacros(m.macros) then return false end
    if m.actions ~= nil then
        if type(m.actions) ~= "table" then return false end
        for slot, a in pairs(m.actions) do
            if not (Int(slot) and slot <= ASS.Cover.MAX) or not GoodAction(a, macros) then return false end
        end
    end
    if m.bindings ~= nil and not GoodBindings(m.bindings) then return false end
    if m.pet ~= nil and not GoodPet(m.pet) then return false end
    return true
end

------------------------------------------------------------
-- Share and Import
------------------------------------------------------------

-- What Share and Import say for each refusal.
Share.COPY = {
    ["too-long"] = "This string is too long to be a loadout.",
    ["bad-envelope"] = "This isn't an AltStableSync loadout string.",
    ["not-a-share"] = "This isn't an AltStableSync loadout string.",
    ["bad-checksum"] = "This string is damaged (it was cut short or changed).",
    ["bad-share"] = "This string is damaged.",
    ["newer-schema"] = "This string was made by a newer AltStableSync: update this one first.",
    ["older-schema"] = "This string was made by an older AltStableSync: save the loadout again there and share it again.",
    ["encode-failed"] = "Couldn't make the string; try again.",
    ["too-large"] = "This loadout is too large to share.",
    ["cant-share"] = "This loadout holds something a share string can't carry (a name or macro over the limits).",
}

function Share.Copy(code) return Share.COPY[code] or tostring(code) end

-- The share string for `entry`, or nil plus a code. It holds the five
-- fields only, and passes this build's own decoder and validator.
function Share.Encode(entry)
    if type(entry) ~= "table" or entry.kind ~= "loadout" or entry.deleted or type(entry.modules) ~= "table" then
        return nil, "cant-share"
    end
    local C = ASS.Catalog.Copy
    local x = { kind = "loadout", class = entry.class, category = entry.category, name = entry.name, modules = C(entry.modules) }
    local text, err = ASS.Envelope.EncodeShare(x)
    if not text then return nil, err end
    -- The string as Import will read it: its size limits, then the fields.
    local back, berr = ASS.Envelope.DecodeShare(text)
    if not back then return nil, berr == "too-long" and "too-large" or "encode-failed" end
    if not Share.Valid(back) then return nil, "cant-share" end
    return text
end

-- The pasted text -> the validated share, or nil plus a code. Class and
-- name aren't checked here: the dialog says which class a string is for,
-- and the name is chosen there.
function Share.Decode(text)
    local x, err = ASS.Envelope.DecodeShare(text)
    if not x then return nil, err end
    if not Share.Valid(x) then return nil, "bad-share" end
    return x
end

-- The class's display name.
function Share.ClassLabel(class)
    local names = _G.LOCALIZED_CLASS_NAMES_MALE
    if type(names) == "table" and type(names[class]) == "string" then return names[class] end
    local s = tostring(class):lower()
    return (s:gsub("^%l", string.upper))
end

-- Text from a string, shown as it is: "|" doubled, so no colour, link or
-- texture markup renders. Only for display; the stored text is unchanged.
function Share.Literal(s) return (tostring(s):gsub("|", "||")) end
