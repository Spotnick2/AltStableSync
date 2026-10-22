------------------------------------------------------------
-- Offer.lua - the first-login offer (#10, docs/DESIGN.md "First-login offer")
--
-- Once per session, after readiness, out of combat and with Edit Mode and the
-- chat settings closed, a character that hasn't answered the offer and can
-- be offered a UI setup sees: "Make yourself at home." with Preview and apply
-- (one setup) or Choose (several), and Skip... It only opens a preview or the
-- panel's UI setup tab: the offer itself writes no game state and no catalog
-- entry.
--
-- Answered (owner, 2026-10-22) only by a confirmed skip or a completed apply
-- (UISetup.Apply records it, whatever opened the preview), in
-- `AltStableSyncChar.onboarding = { handled = true }`, never cleared.
--   Welcome: Escape or Skip... -> the skip confirmation.
--   Confirmation: Skip setup (answers) / Back -> the Welcome; Escape closes
--     it unanswered: the offer returns at the next login.
--   Apply preview opened from the Welcome: Cancel or Escape -> the Welcome.
--   Choose opens the tab; the offer returns next login unless answered.
-- Each step after a close runs on the next frame update (never inside the
-- shared preview frame's own OnHide), and only if the character is still
-- unanswered, no preview is open and the player isn't in combat; otherwise
-- it is dropped until the next login.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Offer = {}
ASS.Offer = Offer

local PERIOD = 1

local state = { started = false, shown = false }

local function Print(msg)
    if ASS.Print then ASS.Print(msg) end
end

local function Handled()
    return type(ASS.char) == "table" and type(ASS.char.onboarding) == "table" and ASS.char.onboarding.handled == true
end

local function MarkHandled() ASS.char.onboarding = { handled = true } end

local function Me()
    local name, realm = UnitFullName("player")
    return tostring(name) .. "-" .. tostring(realm)
end

-- The UI setups this character can be offered: live, not a conflict copy, and
-- not saved from this character (a missing provenance is not proof it was).
function Offer.Candidates()
    local out = {}
    if not (ASS.db and ASS.Catalog) then return out end
    local me = Me()
    for _, e in ipairs(ASS.Catalog.ListAll("ui")) do
        local from = type(e.provenance) == "table" and e.provenance.sourceChar
        if not e.conflict and from ~= me then out[#out + 1] = e end
    end
    return out
end

function Offer.Eligible()
    if ASS.disabled or not ASS.db or not ASS.char or Handled() then return false end
    return #Offer.Candidates() > 0
end

-- One pending step, run on the next update of its own frame.
local step = CreateFrame("Frame")
local pending
local function Later(fn)
    pending = fn
    step:SetScript("OnUpdate", function(self)
        self:SetScript("OnUpdate", nil)
        local f = pending
        pending = nil
        if f then f() end
    end)
end
Offer._Flush = function() local f = step:GetScript("OnUpdate"); if f then f(step, 0) end end

-- Whether a step may show now. `force` (/altsync ui offer) shows it on a
-- character that already answered. A step only shows our own window, so it
-- doesn't wait for readiness: on a new character an addon rewriting its
-- macro (RestedXP) kept the gate closed and dropped the confirmation (beta,
-- 2026-10-22). The apply preview it may open still checks everything.
local function CanShow(force)
    if ASS.disabled or not ASS.db or not ASS.char then return false end
    if not force and Handled() then return false end
    if ASS.Preview.Shown() then return false end
    if InCombatLockdown() then return false end
    return true
end

local Welcome

local function Confirm(force)
    ASS.Preview.Show({
        title = "Skip setting up?",
        lines = { "Skip setting up this character? You won't be asked again on it.",
                  "", "You can still apply a UI setup any time: /altsync, UI setup tab." },
        confirm = "Skip setup",
        cancel = "Back",
        onConfirm = function() if not force then MarkHandled() end end,
        onCancelButton = function() Later(function() if CanShow(force) then Welcome(force) end end) end,
    })
end

-- The Welcome window. Returns true when shown.
Welcome = function(force)
    local list = Offer.Candidates()
    if #list == 0 then return false end
    local one = #list == 1 and list[1]
    local lines
    if one then
        lines = { ("Make yourself at home. Start with your saved UI preferences: %s."):format(tostring(one.name)),
                  "", "Preview and apply shows every change first; nothing changes until you confirm it." }
    else
        lines = { "Make yourself at home. Choose a saved UI setup to start with.",
                  "", "Choose opens the UI setup tab; nothing changes until you apply one and confirm it." }
    end
    ASS.Preview.Show({
        title = "Welcome",
        lines = lines,
        confirm = one and "Preview and apply" or "Choose",
        cancel = "Skip...",
        -- Escape, or Skip... (the cancel button hides the frame): ask first.
        onCancel = function() Later(function() if CanShow(force) then Confirm(force) end end) end,
        onConfirm = function()
            -- The catalog may have changed since the offer appeared.
            if one then
                local e = ASS.Catalog.Get(one.id)
                if not e or e.deleted then Print("That UI setup was deleted.") return end
                ASS.Commands.ApplyUI(e.id, function()
                    Later(function() if CanShow(force) then Welcome(force) end end)
                end)
            elseif ASS.Panel and ASS.Panel.Open then
                ASS.Panel.Open("ui")
            end
        end,
    })
    return true
end

-- Show the offer now. `force` (/altsync ui offer, for testing) shows it
-- whether or not this character answered, and its Skip doesn't record an
-- answer (a real apply confirmed from it still does). Returns true when shown.
function Offer.Show(force)
    if ASS.disabled or not ASS.db then return false end
    if #Offer.Candidates() == 0 then
        if force then Print("No UI setup to offer: save one on another character first (/altsync ui saveas <name>).") end
        return false
    end
    if ASS.Preview.Shown() then
        if force then Print("Close the open preview first.") end
        return false
    end
    if not Welcome(force) then return false end
    state.shown = true
    return true
end

-- One ticker per session, started at the first PLAYER_ENTERING_WORLD. It
-- skips a tick while a write would be blocked or a preview is open, and stops
-- once the offer was shown, answered, or the addon is disabled. A catalog
-- that arrives by sync later in the session is offered on a later tick.
local frame = CreateFrame("Frame")
local elapsed = 0

local function Stop() frame:SetScript("OnUpdate", nil) end

local function Tick(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < PERIOD then return end
    elapsed = 0
    if state.shown or ASS.disabled or Handled() then Stop() return end
    if not ASS.db then return end
    if ASS.UISetup.Blocked() or ASS.Preview.Shown() then return end
    if Offer.Eligible() and Offer.Show(false) then Stop() end
end
Offer._Tick = Tick

pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
    if state.started then return end
    state.started = true
    frame:SetScript("OnUpdate", Tick)
end)
