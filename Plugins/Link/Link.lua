------------------------------------------------------------
-- Link.lua - AltStableSyncLink: LibAccountSync glue for the catalog (#18)
--
-- A separate addon so LibAccountSync's store (AltStableSyncLAS, with the
-- household key) is written to AltStableSyncLink.lua and never to
-- AltStableSync.lua, the file the beta->live transfer copies (docs/DESIGN.md).
--
-- Starts only when the core addon has a usable DB; a refused schema disables
-- sync too. Messages mode is required (r5): without it a stream that
-- completes after a newer one is dropped, which would lose entries.
-- Nothing here writes game state: received entries go to Catalog.Upsert.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Link = { state = "starting" }
ASS.Link = Link

local ADDON_NAME = "AltStableSyncLink"
local TAG = "AltStableSync"

local function Print(msg) if ASS.Print then ASS.Print(msg) end end

local function Disable(why)
    Link.state, Link.why, Link.sync = "disabled", why, nil
end

function Link.Start()
    if Link.sync then return true end
    if ASS.disabled then Disable("AltStableSync is disabled: " .. tostring(ASS.disabled)) return false end
    if not (ASS.db and ASS.Catalog and ASS.Envelope and ASS.Sync) then
        Disable("AltStableSync isn't loaded") return false
    end
    local lib = LibStub and LibStub("LibAccountSync-1.0", true)
    if not lib then Disable("LibAccountSync is missing") return false end
    AltStableSyncLAS = AltStableSyncLAS or {}
    local ok, inst = pcall(lib.New, lib, {
        addon = TAG,
        store = function() return AltStableSyncLAS end,
        maxPayload = 16384,
        messages = true,
        report = function(text) Print(text) end,
    })
    if not ok or type(inst) ~= "table" then Disable("LibAccountSync refused: " .. tostring(inst)) return false end
    if inst.messages ~= true or type(inst.SendTo) ~= "function" then
        Disable("an older LibAccountSync copy is loaded (needs r5 messages mode)") return false
    end
    local sync = ASS.Sync.New({
        catalog = ASS.Catalog,
        envelope = ASS.Envelope,
        transport = {
            Send = function(msg) return inst.Send(msg) end,
            SendTo = function(guid, msg) return inst.SendTo(guid, msg) end,
            Peers = function() return inst.Peers() end,
        },
        now = GetTime,
        report = Print,
        maxPayload = 16384,
        gen = ASS.writer,
    })
    inst.OnMessage(function(payload, sender, sid) sync.Receive(payload, sender, sid) end)
    Link.lib, Link.sync, Link.state, Link.why = inst, sync, "on", nil
    ASS.Catalog.OnLocalWrite(function() if Link.sync and inst.IsEnabled() then Link.sync.LocalWrite() end end)
    return true
end

function Link.Tick()
    if Link.sync and Link.lib.IsEnabled() then Link.sync.Tick() end
end

-- "confirmed", "pending", "too large", or nil (no peer, or sync off).
function Link.EntryStatus(e)
    if not (Link.sync and Link.lib.IsEnabled()) then return nil end
    return Link.sync.EntryStatus(e)
end

------------------------------------------------------------
-- /altsync link [refresh|on|off]
------------------------------------------------------------

local function Status()
    if not Link.sync then Print("Link: off - " .. tostring(Link.why or "not started")) return end
    local on = Link.lib.IsEnabled()
    Print("Link: " .. (on and "on" or "off (/altsync link on)"))
    local peers = Link.sync.Peers()
    if #peers == 0 then Print("  No other account of yours is online.") end
    -- The entries a player sees: live, not conflict copies (those show as
    -- conflicts until resolved; the other account never lists our copy).
    local entries, conflicts = {}, 0
    for _, kind in ipairs({ "loadout", "ui" }) do
        for id, e in pairs(ASS.db.presets) do
            if type(e) == "table" and e.kind == kind and not e.deleted then
                if e.conflict then conflicts = conflicts + 1 else entries[#entries + 1] = e end
            end
        end
    end
    for _, p in ipairs(peers) do
        if not p.heard then
            Print(("  %s: online, no reply yet (AltStableSyncLink not running there?)"):format(p.label))
        else
            local n = { confirmed = 0, pending = 0, ["too large"] = 0 }
            for _, e in ipairs(entries) do
                local st = Link.sync.EntryStatus(e, p.guid) or "pending"
                n[st] = (n[st] or 0) + 1
            end
            local out, queued = Link.sync.Outstanding(p.guid)
            Print(("  %s: %d confirmed, %d pending%s%s"):format(p.label, n.confirmed, n.pending,
                n["too large"] > 0 and (", " .. n["too large"] .. " too large to sync") or "",
                (out + queued) > 0 and (", fetching " .. (out + queued)) or ""))
        end
    end
    if conflicts > 0 then Print(("  %d conflict%s to resolve: /altsync conflicts"):format(conflicts, conflicts == 1 and "" or "s")) end
    if Link.lib.Diagnostics then
        for line in Link.lib.Diagnostics() do Print("  " .. tostring(line)) end
    end
end

local function Command(arg)
    local sub = tostring(arg or ""):lower():match("^%s*(%S*)")
    if sub == "" or sub == "status" then return Status() end
    if not Link.sync then Print("Link: off - " .. tostring(Link.why)) return end
    if sub == "refresh" then
        if not Link.lib.IsEnabled() then Print("Link: off (/altsync link on)") return end
        local took = Link.sync.Refresh()
        Print((took or 0) > 0
            and "Link: sent this account's list; entries that differ are fetched in the background."
            or "Link: no other account took the list yet; it is sent again in a few seconds.")
    elseif sub == "on" or sub == "off" then
        Link.lib.SetEnabled(sub == "on")
        Print("Link: " .. sub)
        if sub == "on" then Link.sync.Refresh() end
    else
        Print("/altsync link [refresh | on | off]")
    end
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        self:UnregisterEvent("ADDON_LOADED")
        if ASS.Commands then ASS.Commands.link = Command end
        Link.Start()
    elseif event == "PLAYER_LOGIN" then
        -- The core's ADDON_LOADED is normally first; if not, try once more.
        if not Link.sync and Link.why == "AltStableSync isn't loaded" then Link.Start() end
    end
end)
local elapsed = 0
frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed >= 1 then elapsed = 0; Link.Tick() end
end)

Link._test = { frame = frame, Command = Command }
