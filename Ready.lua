------------------------------------------------------------
-- Ready.lua - the readiness gate (docs/DESIGN.md safety rule 5)
--
-- Capture and plan wait until PLAYER_ENTERING_WORLD has fired, the spellbook
-- has entries, and 2 s have passed since entering the world and since the
-- last UPDATE_MACROS / UPDATE_BINDINGS (no event yet is not "quiet"): the
-- first UPDATE_MACROS carries account macros only and the first
-- UPDATE_BINDINGS still-nil keys (measured on a fresh login, 70245). The
-- /reload order is measured by #29; until then this gate is provisional.
-- It only answers "ready?": no event here ever starts or resumes anything.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local QUIET = 2

local Ready = {}
ASS.Ready = Ready

local state = { entered = false, enteredAt = nil, lastUpdate = nil }

local frame = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "UPDATE_MACROS", "UPDATE_BINDINGS" }) do
    pcall(frame.RegisterEvent, frame, e)
end
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        state.entered = true
        state.enteredAt = GetTime()
    else
        state.lastUpdate = GetTime()
    end
end)

-- true, or false plus why (for the "Waiting for character data." copy).
function Ready.IsReady()
    if not state.entered then return false, "not in the world yet" end
    -- The cheap check first: a waiting caller (#7's step 2) polls this.
    local since = math.max(state.enteredAt or 0, state.lastUpdate or 0)
    if GetTime() - since < QUIET then
        return false, "macros or bindings still loading"
    end
    local book = ASS.Game.Spellbook()
    if next(book.byId) == nil then return false, "spellbook not loaded" end
    return true
end

