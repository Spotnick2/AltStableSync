------------------------------------------------------------
-- Measure.lua - AltStableSyncProbe's measurements (ForeverProbe module)
--
-- Unlike AltStableSyncProbe.lua (which only reads), these procedures write
-- to the client, and only to what they create themselves:
--   `/fp steps sync icons` (#105): one character macro named ICON_PROBE,
--   created, edited and deleted here. It never touches another macro, a
--   bar, a key or a setting. A macro of that name that already exists stops
--   the procedure: it was never ours to edit.
-- Results: each step's detail in ForeverProbeDB.steps.records, and a line
-- in the /fp console and the module's saved log.
------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe                  -- AltStableSyncProbe.lua, loaded first
local function say(msg) Probe:Say(msg) end
local function api(name) return rawget(_G, name) end

------------------------------------------------------------
-- #105: a macro's shown icon (GetMacroInfo) and its chosen icon
-- (C_Macro.GetSelectedMacroIcon), as Blizzard's macro editor reads it.
------------------------------------------------------------

local ICON_PROBE = "ASSIconProbe"       -- 12 characters: under the 16-byte limit
local QUESTION = 134400                 -- INV_Misc_QuestionMark
local CHOSEN = 134414                   -- Hearthstone's icon: an icon in GetMacroIcons' range (forever-api-notes.md, macro edit)
local ATTACK = 6603                     -- Attack: every class knows it
local UNKNOWN = "Xyzzy Probe Spell"     -- no such spell

local function attackName()
    local S = api("C_Spell")
    local name = S and S.GetSpellName and S.GetSpellName(ATTACK)
    return type(name) == "string" and name ~= "" and name or "Attack"
end

local function attackIcon()
    local S = api("C_Spell")
    local ok, icon = pcall(function() return S and S.GetSpellTexture and S.GetSpellTexture(ATTACK) end)
    return ok and icon or nil
end

-- The probe macro's index, or nil; errors when there are several.
local function probeIndex()
    local idx = api("GetMacroIndexByName")
    local i = idx and idx(ICON_PROBE)
    if type(i) ~= "number" or i == 0 then return nil end
    return i
end

local function outOfCombat()
    local f = api("InCombatLockdown")
    if f and f() then error("in combat: wait until it ends, then Retry", 0) end
end

-- Both icons of the probe macro, and what the body is now.
local function readIcons(label)
    local i = probeIndex()
    if not i then error("the probe macro isn't there", 0) end
    local okI, name, shown, body = pcall(api("GetMacroInfo"), i)
    local M = api("C_Macro")
    local okS, chosen = false, "C_Macro.GetSelectedMacroIcon missing"
    if M and M.GetSelectedMacroIcon then okS, chosen = pcall(M.GetSelectedMacroIcon, i) end
    local r = { label = label, index = i, name = okI and name or nil, shown = okI and shown or ("error: " .. tostring(name)),
                chosen = okS and chosen or ("error: " .. tostring(chosen)), body = okI and body or nil,
                attackIcon = attackIcon() }
    say(("icons %s: shown %s, chosen %s (Attack's icon %s)"):format(label, tostring(r.shown), tostring(r.chosen),
        tostring(r.attackIcon)))
    return r
end

local function body(showtooltip, spell, extra)
    return (showtooltip and "#showtooltip\n" or "") .. "/cast " .. spell .. (extra or "")
end

local function edit(icon, text)
    outOfCombat()
    local i = probeIndex()
    if not i then error("the probe macro isn't there: start again from step 1", 0) end
    local ok, err = pcall(api("EditMacro"), i, ICON_PROBE, icon, text)
    if not ok then error("EditMacro failed: " .. tostring(err), 0) end
end

local function create(icon, text)
    outOfCombat()
    if probeIndex() then error("a macro named " .. ICON_PROBE .. " already exists", 0) end
    local ok, err = pcall(api("CreateMacro"), ICON_PROBE, icon, text, true)
    if not ok then error("CreateMacro failed: " .. tostring(err), 0) end
end

local function delete()
    outOfCombat()
    local i = probeIndex()
    if i then
        local ok, err = pcall(api("DeleteMacro"), i)
        if not ok then error("DeleteMacro failed: " .. tostring(err), 0) end
    end
    return probeIndex() == nil
end

-- A case: write, read at once, then read again a second later (the shown
-- icon may follow on the next frame).
local ISTEPS = { title = "Macro icons: shown vs chosen (#105)", rev = 1 }
local function case(label, text, write)
    ISTEPS[#ISTEPS + 1] = { text = text, button = "Run", run = function() write(); return readIcons(label .. " now") end }
    local since
    ISTEPS[#ISTEPS + 1] = { text = "Reading again in a second.", timeout = 10,
        wait = function()
            local now = api("GetTime")()
            since = since or now
            if now - since < 1 then return false, "waiting a second" end
            since = nil
            return true, readIcons(label .. " later")
        end }
end

ISTEPS[#ISTEPS + 1] = { text = "Out of combat, with a free character macro slot. This creates a character macro named "
    .. ICON_PROBE .. ", edits it, and deletes it at the end. Nothing else is changed. Press Next." }
ISTEPS[#ISTEPS + 1] = { text = "Checking there's no macro of that name yet.", auto = true, run = function()
    if probeIndex() then error("a macro named " .. ICON_PROBE .. " already exists: delete it by hand, then Retry", 0) end
    return "none", attackName(), attackIcon()
end }
case("a: ? + #showtooltip + Attack", "Create it with the \"?\" icon, #showtooltip and /cast Attack.",
    function() create(QUESTION, body(true, attackName())) end)
case("b: ? + Attack, no #showtooltip", "Same icon, /cast Attack without #showtooltip.",
    function() edit(QUESTION, body(false, attackName())) end)
case("c: ? + #showtooltip + unknown spell", "Same icon, #showtooltip and a spell that doesn't exist.",
    function() edit(QUESTION, body(true, UNKNOWN)) end)
case("d: chosen icon + #showtooltip + Attack", "A chosen icon (Hearthstone's), #showtooltip and /cast Attack.",
    function() edit(CHOSEN, body(true, attackName())) end)
case("e: body only (icon nil)", "Only the text changes: EditMacro with no icon.", function()
    outOfCombat()
    local i = probeIndex()
    if not i then error("the probe macro isn't there: start again from step 1", 0) end
    local ok, err = pcall(api("EditMacro"), i, nil, nil, body(true, attackName(), "\n/stopattack"))
    if not ok then error("EditMacro failed: " .. tostring(err), 0) end
end)
case("f: back to ?", "Back to the \"?\" icon, same text.",
    function() edit(QUESTION, body(true, attackName(), "\n/stopattack")) end)
case("g: created by name", "Deleted, then created again with the icon given by name (\"INV_Misc_QuestionMark\").",
    function()
        if not delete() then error("couldn't delete the probe macro", 0) end
        create("INV_Misc_QuestionMark", body(true, attackName()))
    end)
ISTEPS[#ISTEPS + 1] = { text = "Delete the probe macro.", button = "Delete", run = function()
    if not delete() then error("couldn't delete the probe macro: delete " .. ICON_PROBE .. " by hand", 0) end
    return "deleted"
end, check = function() return probeIndex() == nil, "no macro named " .. ICON_PROBE .. " left" end }
ISTEPS[#ISTEPS + 1] = { text = "Type /reload (or press Reload now) so the results are written to disk.", reload = true }

Probe:Steps("icons", ISTEPS)

NS._measure = { ICON_PROBE = ICON_PROBE, probeIndex = probeIndex, readIcons = readIcons, ISTEPS = ISTEPS }
