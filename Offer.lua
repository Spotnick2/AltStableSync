------------------------------------------------------------
-- Offer.lua - the first-login offer (#10, docs/DESIGN.md "First-login offer")
--
-- Once per session, after readiness, out of combat and with Edit Mode and the
-- chat settings closed, a character that hasn't answered the offer and can
-- be offered a UI setup sees: "Make yourself at home." with Not now and
-- Preview and apply (one setup) or Choose (several). It only opens a preview
-- or the panel's UI setup tab: the offer writes no game state and no catalog
-- entry. `AltStableSyncChar.onboarding = { handled = true }` is set by Not
-- now, and when the preview or the tab actually opened. Escape is no answer:
-- the offer comes back at the next login.
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

-- Show the offer now. `force` (/altsync ui offer, for testing) shows it
-- whether or not this character answered, and its buttons don't record an
-- answer. Returns true when shown.
function Offer.Show(force)
    if ASS.disabled or not ASS.db then return false end
    local list = Offer.Candidates()
    if #list == 0 then
        if force then Print("No UI setup to offer: save one on another character first (/altsync ui saveas <name>).") end
        return false
    end
    if ASS.Preview.Shown() then
        if force then Print("Close the open preview first.") end
        return false
    end
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
        cancel = "Not now",
        onCancelButton = function() if not force then MarkHandled() end end,
        onConfirm = function()
            -- The catalog may have changed since the offer appeared.
            if one then
                local e = ASS.Catalog.Get(one.id)
                if not e or e.deleted then Print("That UI setup was deleted.") return end
                if ASS.Commands.ApplyUI(e.id) and not force then MarkHandled() end
            elseif ASS.Panel and ASS.Panel.Open then
                ASS.Panel.Open("ui")
                if not force then MarkHandled() end
            end
        end,
    })
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
