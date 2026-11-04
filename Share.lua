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
-- A macro name: 16 bytes in a share string; 64 in the catalog, since the
-- client's own limit (letters or bytes) isn't measured (#98, E8).
local MACRO_NAME = { strict = 16, lenient = 64, comparison = 64 }
local COMMAND_MAX = 64       -- bytes: an unmanaged binding command's name (lenient)
local KIND_MAX = 32          -- bytes: the kind of an action in a slot this build doesn't manage
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
-- The loaded record's comparison also carries a macro action's icon (Merge
-- puts it there, Loadout.lua): never in a catalog entry or a share string.
local MACRO_COMPARED = { kind = true, name = true, body = true, scope = true, icon = true }
local UNSUPPORTED = { kind = true, what = true }

local function Icon(v) return v == nil or Int(v) or Str(v, 256, true) end

local function GoodAction(a, macros, mode)
    if type(a) ~= "table" then return false end
    if a.kind == "spell" then
        return Only(a, SPELL) and Int(a.id) and (a.name == nil or Str(a.name, 100, true))
            and (a.policy == nil or a.policy == "exact" or a.policy == "highest") and (a.class == nil or a.class == true)
    elseif a.kind == "item" then
        return Only(a, ITEM) and Int(a.id)
    elseif a.kind == "macro" then
        local fields = mode == "comparison" and MACRO_COMPARED or MACRO
        if not (Only(a, fields) and Str(a.name, MACRO_NAME[mode], true) and Str(a.body, MACRO_BODY_MAX, false, true)
                and Icon(a.icon)) then
            return false
        end
        if a.scope == "char" then return macros[a.name] ~= nil end
        return a.scope == "account"
    elseif a.kind == "unsupported" then
        return Only(a, UNSUPPORTED) and (a.what == nil or Str(a.what, 64, true))
    end
    return false
end

local DEF = { body = true, icon = true }
local function GoodMacros(m, mode)
    if type(m) ~= "table" then return false end
    local n = 0
    for name, def in pairs(m) do
        n = n + 1
        if n > ASS.Game.MAX_CHAR_MACROS then return false end
        if not Str(name, MACRO_NAME[mode], true) or type(def) ~= "table" or not Only(def, DEF) then return false end
        if not Str(def.body, MACRO_BODY_MAX, false, true) then return false end
        if not Icon(def.icon) then return false end
    end
    return true
end

-- Strict: the commands this build captures, nothing else. Otherwise any
-- command with a name (an older or newer build's, kept by Save, A35; Load
-- binds managed commands only, so it is inert), with the same key bounds.
local function GoodBindings(b, mode)
    if type(b) ~= "table" then return false end
    local managed = {}
    for _, cmd in ipairs(ASS.Game.COMMANDS) do managed[cmd] = true end
    for cmd, keys in pairs(b) do
        if mode == "strict" then
            if not managed[cmd] then return false end
        elseif not Str(cmd, COMMAND_MAX, true) then
            return false
        end
        local function key(k) return Str(k, 32, true) end
        if mode == "strict" then
            if not List(keys, KEYS_MAX, key) then return false end
        else
            -- Keys by position: a hole is allowed (Load reads up to maxn, so
            -- a missing first key never hides the second).
            if type(keys) ~= "table" then return false end
            for i, k in pairs(keys) do
                if not (Int(i) and i <= KEYS_MAX) or not key(k) then return false end
            end
        end
    end
    return true
end

local LAYOUT = { family = true, locale = true, slots = true }
local LAYOUT_COMPARED = { family = true, locale = true, slots = true, unavailable = true }
local TOKEN, PETSPELL = { kind = true, token = true }, { kind = true, id = true, name = true }
local function GoodPetSlot(s)
    if s == false then return true end
    if type(s) ~= "table" then return false end
    if s.kind == "token" then return Only(s, TOKEN) and Str(s.token, 32, true) end
    if s.kind == "spell" then return Only(s, PETSPELL) and Int(s.id) and Str(s.name, 100, true) end
    return false
end

-- A map of slots a load couldn't fill: { [slot] = reason }.
local function GoodUnavailable(u, max)
    if type(u) ~= "table" then return false end
    for k, why in pairs(u) do
        if not (Int(k) and k <= max) or not Str(why, 64, true) then return false end
    end
    return true
end

local function GoodPet(p, mode)
    if type(p) ~= "table" then return false end
    -- A comparison's layout may list the pet slots its load couldn't fill
    -- (Loadout.Load's record, read by Pet.Merge).
    local fields = mode == "comparison" and LAYOUT_COMPARED or LAYOUT
    local n = 0
    for fam, layout in pairs(p) do
        n = n + 1
        if n > FAMILIES_MAX or not Int(fam) or type(layout) ~= "table" or not Only(layout, fields) then return false end
        if layout.unavailable ~= nil and not GoodUnavailable(layout.unavailable, PET_SLOTS) then return false end
        -- A family name is the client's, in its language: 64 bytes in the catalog.
        if not Str(layout.family, mode == "strict" and 32 or 64, true) then return false end
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

-- A loadout's modules, in one of three modes (#98, E1):
--   "strict"     a share string, from anyone: only the parts this build
--                captures, managed commands only, 16-byte macro names;
--   "lenient"    a catalog entry (received by sync, or Create, Replace and
--                Undo here): the known parts checked the same way, while
--                what A35 keeps from an older or newer build passes as it
--                is - an unknown module key, any named binding command, an
--                action in a slot this build doesn't manage (listed by Load,
--                never applied) - and macro names up to 64 bytes;
--   "comparison" the loaded record's `after`: lenient, plus the fields only
--                a record carries (a macro action's icon, a pet layout's
--                unavailable slots).
-- A malformed known part is refused in every mode.
function Share.GoodModules(m, mode)
    mode = mode or "strict"
    if not MACRO_NAME[mode] then return false end
    if type(m) ~= "table" or not GoodCover(m.cover) then return false end
    if mode == "strict" and not Only(m, MODULE_KEYS) then return false end
    local macros = m.macros or {}
    if m.macros ~= nil and not GoodMacros(m.macros, mode) then return false end
    if m.actions ~= nil then
        if type(m.actions) ~= "table" then return false end
        local managed = ASS.Game.IS_SLOT
        for slot, a in pairs(m.actions) do
            if not (Int(slot) and slot <= ASS.Cover.MAX) then return false end
            if mode ~= "strict" and not managed[slot] then
                if type(a) ~= "table" or not Str(a.kind, KIND_MAX, true) then return false end
            elseif not GoodAction(a, macros, mode) then
                return false
            end
        end
    end
    if m.bindings ~= nil and not GoodBindings(m.bindings, mode) then return false end
    if m.pet ~= nil and not GoodPet(m.pet, mode) then return false end
    return true
end

-- Whether `x` is a share this build can import: true, or false.
function Share.Valid(x)
    if type(x) ~= "table" or not Only(x, SHARE) or x.kind ~= "loadout" then return false end
    if not (Str(x.class, 32, true) and Str(x.category, 32, true) and Str(x.name, NAME_MAX, true)) then return false end
    return Share.GoodModules(x.modules, "strict")
end

-- A record's map of slots the load couldn't fill: absent, or slot -> reason.
function Share.GoodUnavailable(u)
    return u == nil or GoodUnavailable(u, ASS.Cover.MAX)
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

-- Text from a string, shown as it is (Core's ASS.Literal, #75).
function Share.Literal(s) return ASS.Literal(s) end
