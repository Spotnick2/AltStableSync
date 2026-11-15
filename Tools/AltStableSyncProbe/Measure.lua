------------------------------------------------------------
-- Measure.lua - AltStableSyncProbe's measurements (ForeverProbe module)
--
-- Unlike AltStableSyncProbe.lua (which only reads), these procedures write
-- to the client, and only to what they create themselves:
--   `/fp steps sync icons` (#105): one character macro named ICON_PROBE,
--   created, edited and deleted here. It never touches another macro, a
--   bar, a key or a setting. A macro of that name that already exists stops
--   the procedure: it was never ours to edit.
--   `/fp steps sync contexts` (#106): one key chord, TEST_KEY, bound in
--   memory (never saved) in two binding contexts, then put back as it was.
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

------------------------------------------------------------
-- #106: binding contexts. One test chord, bound in memory (never saved) in
-- the None context and in the gamepad's at once; every read with and
-- without a context; then each context's original put back. The originals
-- are saved first (AltStableSyncProbeDB.contexts), and `/fp sync contexts
-- restore` puts them back if the run stops in between.
------------------------------------------------------------

local TEST_KEY = "ALT-CTRL-SHIFT-F11"
local NONE_CMD, PAD_CMD = "ACTIONBUTTON12", "GAMEPADACTIONBUTTON1"

local function contexts()
    local E = api("Enum")
    local C = E and E.BindingContext
    if type(C) ~= "table" then error("no Enum.BindingContext on this client", 0) end
    return C, C.None, C.GamepadModeInGameCore
end

local function pack(...) return { n = select("#", ...), ... } end
local function show(p, from)
    local out = {}
    for i = from or 1, p.n do out[#out + 1] = tostring(p[i]) end
    return table.concat(out, ", ")
end
local function call(name, ...)
    local fn = api(name)
    if type(fn) ~= "function" then return name .. " missing" end
    local p = pack(pcall(fn, ...))
    if not p[1] then return "error: " .. tostring(p[2]) end
    return show(p, 2)
end
local function ctxOf(cmd)
    local KB = api("C_KeyBindings")
    if type(KB) ~= "table" or type(KB.GetBindingContextForAction) ~= "function" then return "lookup missing" end
    local ok, ctx = pcall(KB.GetBindingContextForAction, cmd)
    return ok and tostring(ctx) or ("error: " .. tostring(ctx))
end

local function state()
    local C = contexts()
    local KB = api("C_KeyBindings")
    local active = {}
    for name, v in pairs(C) do
        local ok, on = false, nil
        if KB and KB.IsBindingContextActive then ok, on = pcall(KB.IsBindingContextActive, v) end
        active[#active + 1] = name .. "=" .. tostring(v) .. (ok and (on and " active" or " inactive") or "")
    end
    table.sort(active)
    local cvar = api("C_CVar")
    local pad = cvar and cvar.GetCVar and cvar.GetCVar("GamePadEnable")
    local r = { contexts = table.concat(active, "; "), GamePadEnable = tostring(pad),
                ACTIONBUTTON1 = ctxOf("ACTIONBUTTON1"), [PAD_CMD] = ctxOf(PAD_CMD), OPENRADIAL = ctxOf("OPENRADIAL"),
                JUMP = ctxOf("JUMP"), click = ctxOf("CLICK AltStableSyncProbeNone:LeftButton") }
    say("contexts: " .. r.contexts .. " | GamePadEnable " .. r.GamePadEnable .. " | ACTIONBUTTON1 " .. r.ACTIONBUTTON1
        .. ", " .. PAD_CMD .. " " .. r[PAD_CMD] .. ", OPENRADIAL " .. r.OPENRADIAL .. ", JUMP " .. r.JUMP
        .. ", a CLICK binding " .. r.click)
    return r
end

-- Every read of the test chord and of the two commands, with and without a context.
local function reads(label)
    local _, NONE, PAD = contexts()
    local r = {
        label = label,
        actionNoCtx = call("GetBindingAction", TEST_KEY),
        actionNone = call("GetBindingAction", TEST_KEY, nil, NONE),
        actionPad = call("GetBindingAction", TEST_KEY, nil, PAD),
        noneKeysNoCtx = call("GetBindingKey", NONE_CMD),
        noneKeysNone = call("GetBindingKey", NONE_CMD, nil, NONE),
        padKeysNoCtx = call("GetBindingKey", PAD_CMD),
        padKeysPad = call("GetBindingKey", PAD_CMD, nil, PAD),
        padKeysNone = call("GetBindingKey", PAD_CMD, nil, NONE),
    }
    say(("contexts %s: %s action: no ctx [%s], None [%s], pad [%s]; %s keys: no ctx [%s], None [%s]; %s keys: no ctx [%s], pad [%s], None [%s]")
        :format(label, TEST_KEY, r.actionNoCtx, r.actionNone, r.actionPad, NONE_CMD, r.noneKeysNoCtx, r.noneKeysNone,
            PAD_CMD, r.padKeysNoCtx, r.padKeysPad, r.padKeysNone))
    return r
end

local function store() return rawget(_G, "AltStableSyncProbeDB") end

-- Put each context's original back (from the saved originals), and check.
local function putBack()
    outOfCombat()
    local db = store()
    local o = db and db.contexts
    if type(o) ~= "table" then return true, "nothing to put back" end
    local set, get = api("SetBinding"), api("GetBindingAction")
    local bad = {}
    for _, c in ipairs(o.originals) do
        local ok, err = pcall(set, o.key, c.action ~= "" and c.action or nil, c.ctx)
        if not ok then bad[#bad + 1] = "context " .. tostring(c.ctx) .. ": " .. tostring(err) end
        local okR, now = pcall(get, o.key, nil, c.ctx)
        if not okR or (now or "") ~= c.action then
            bad[#bad + 1] = ("context %s reads %s, was %s"):format(tostring(c.ctx), tostring(now), tostring(c.action))
        end
    end
    if #bad > 0 then return false, table.concat(bad, "; ") end
    db.contexts = nil
    say("contexts: " .. o.key .. " is back as it was in each context")
    return true, "back as it was"
end

local CSTEPS = { title = "Binding contexts (#106)", rev = 1 }
CSTEPS[#CSTEPS + 1] = { text = "Out of combat. This binds " .. TEST_KEY .. " in memory only (never saved) in two binding "
    .. "contexts, reads it every way, and puts it back as it was. If the run stops before the end, type "
    .. "/fp sync contexts restore. Press Next." }
CSTEPS[#CSTEPS + 1] = { text = "Reading the contexts and the gamepad setting.", auto = true, run = state }
CSTEPS[#CSTEPS + 1] = { text = "Bind the test chord in both contexts (the originals are saved first).", button = "Bind",
    run = function()
        outOfCombat()
        local _, NONE, PAD = contexts()
        local db = store()
        if type(db) ~= "table" then error("the probe's saved table isn't loaded yet", 0) end
        if type(db.contexts) == "table" then error("an earlier run wasn't put back: /fp sync contexts restore first", 0) end
        local get = api("GetBindingAction")
        local originals = {}
        for _, ctx in ipairs({ NONE, PAD }) do
            local ok, a = pcall(get, TEST_KEY, nil, ctx)
            if not ok then error("can't read " .. TEST_KEY .. " in context " .. tostring(ctx) .. ": " .. tostring(a), 0) end
            originals[#originals + 1] = { ctx = ctx, action = a or "" }
        end
        db.contexts = { key = TEST_KEY, originals = originals }
        local set = api("SetBinding")
        local r1 = pack(pcall(set, TEST_KEY, NONE_CMD, NONE))
        local r2 = pack(pcall(set, TEST_KEY, PAD_CMD, PAD))
        return { originals = originals[1].action .. " / " .. originals[2].action, setNone = show(r1), setPad = show(r2) }
    end }
CSTEPS[#CSTEPS + 1] = { text = "Reading it every way.", auto = true, run = function() return reads("bound") end }
CSTEPS[#CSTEPS + 1] = { text = "If you can, turn gamepad mode on now (Options > Controls, or /console GamePadEnable 1), "
    .. "then Next. Skip if you can't." }
CSTEPS[#CSTEPS + 1] = { text = "Reading again.", button = "Read", run = function() return state(), reads("gamepad on?") end }
CSTEPS[#CSTEPS + 1] = { text = "Put gamepad mode back as it was (if you changed it), then Next." }
CSTEPS[#CSTEPS + 1] = { text = "Put the test chord back in each context.", button = "Put back", run = function()
    local ok, why = putBack()
    if not ok then error(why, 0) end
    return why
end, check = function()
    local db = store()
    return not (db and db.contexts), "the originals are back"
end }
CSTEPS[#CSTEPS + 1] = { text = "Type /reload (or press Reload now) so the results are written to disk.", reload = true }
Probe:Steps("contexts", CSTEPS)

Probe:Command("contexts", function(args)
    if tostring(args or ""):match("^%s*restore") then
        local ok, why = putBack()
        say(ok and why or ("contexts: couldn't put it all back: " .. why))
    else
        say("/fp sync contexts restore - put the contexts procedure's test chord back as it was")
    end
end, "contexts restore: put the binding-context test chord back (#106)")

NS._measure = { ICON_PROBE = ICON_PROBE, probeIndex = probeIndex, readIcons = readIcons, ISTEPS = ISTEPS,
                TEST_KEY = TEST_KEY, CSTEPS = CSTEPS, putBack = putBack }
