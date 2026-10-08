------------------------------------------------------------
-- Commands.lua - /altsync commands for the #4 slice (until #9's panel)
--
--   /altsync saveas <name>   Save As: a new loadout in this class's "general"
--   /altsync list            this class's loadouts
--   /altsync load <name>     preview, then load (writes only on confirm)
--   /altsync backups         this character's snapshots
--   /altsync restore [n|op]  preview, then restore exactly (default: newest)
--   /altsync status
-- `save` (over an existing entry) stays disabled until #28 (docs/DESIGN.md).
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Commands = {}
ASS.Commands = Commands

local function Print(msg) ASS.Print(msg) end

local function PlayerClass()
    local _, class = UnitClass("player")
    return class
end

local function FindLoadout(name)
    local want = tostring(name or ""):lower()
    for _, e in ipairs(ASS.Catalog.List("loadout", PlayerClass(), "general")) do
        if tostring(e.name):lower() == want then return e end
    end
end

local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function DescribeAction(a)
    if not a then return "empty" end
    if a.kind == "spell" then
        local name = C_Spell.GetSpellName and C_Spell.GetSpellName(a.id)
        return tostring(name or ("spell " .. a.id))
    end
    if a.kind == "item" then return "item " .. tostring(a.id) end
    if a.kind == "macro" then return "macro " .. tostring(a.name) end
    return tostring(a.what or a.kind)
end

-- The preview's lines for a plan (pure; tested).
function Commands.Describe(plan)
    local lines = {}
    if plan.blocked then return { plan.blocked } end
    if plan.noop and not plan.keysBlocked and #(plan.unavailable or {}) == 0 and #plan.skips == 0 then
        return { "Already matches the selected settings." }
    end
    local nKeys = 0
    for _ in pairs(plan.keys) do nKeys = nKeys + 1 end
    lines[#lines + 1] = ("Actions: %s change."):format(Plural(#plan.actions, "slot"))
    if #plan.creates > 0 then
        lines[#lines + 1] = ("Character macros: %s to create (account macros stay untouched)."):format(Plural(#plan.creates, "macro"))
    end
    if plan.keysBlocked then
        lines[#lines + 1] = "Bindings: not changed. " .. plan.keysBlocked
    else
        lines[#lines + 1] = ("Bindings (Destination: Character): %s change."):format(Plural(nKeys, "key"))
    end
    for _, op in ipairs(plan.actions) do
        lines[#lines + 1] = ("  slot %d: %s -> %s"):format(op.slot, DescribeAction(op.current), DescribeAction(op.target))
    end
    local keys = {}
    for k, v in pairs(plan.keys) do keys[#keys + 1] = { k = k, v = v } end
    table.sort(keys, function(a, b) return a.k < b.k end)
    for _, kv in ipairs(keys) do
        lines[#lines + 1] = ("  %s: %s -> %s"):format(kv.k, kv.v.from or "unbound", kv.v.to or "unbound")
    end
    for _, s in ipairs(plan.skips) do
        lines[#lines + 1] = ("  slot %d left unchanged: %s"):format(s.slot, s.reason)
    end
    for _, u in ipairs(plan.unavailable or {}) do
        lines[#lines + 1] = ("  slot %d can't be restored exactly: %s"):format(u.slot, u.reason)
    end
    if plan.kind == "restore" and #(plan.kept or {}) > 0 then
        lines[#lines + 1] = ("Kept: %s that load created (not deleted)."):format(Plural(#plan.kept, "macro"))
    end
    lines[#lines + 1] = plan.kind == "restore" and "Restore exact captured values. A backup is taken first."
        or "Backup first. Verify every write. Unresolved slots stay untouched."
    return lines
end

local function Report(kind, result, err)
    if not result then
        Print((kind == "load" and "Not loaded: " or "Not restored: ") .. tostring(err))
        return
    end
    if result.noop then Print("Already matches the selected settings.") return end
    local skipped = #(result.skips or {}) + #(result.unavailable or {})
    if result.failed then
        Print(("Stopped (%s at %s): %d slots, %d keys done. Use /altsync restore op to undo, or load again to abandon it.")
            :format(result.failed, tostring(result.at), result.changed, result.keys))
        return
    end
    local msg = ("%s: %d slots, %d keys%s."):format(kind == "load" and "Loaded" or "Restored",
        result.changed, result.keys, result.created > 0 and (", " .. result.created .. " macros created") or "")
    if skipped > 0 then msg = msg .. " " .. skipped .. " left unchanged (see the preview's list)." end
    if result.partial then msg = msg .. " Partial: some entries couldn't be restored exactly." end
    Print(msg)
end

function Commands.saveas(arg)
    local blocked = ASS.Loadout.Blocked()
    if blocked then Print(blocked) return end
    local modules = ASS.Loadout.Capture()
    local name, realm = UnitFullName("player")
    local e, err = ASS.Catalog.Create("loadout", { class = PlayerClass(), category = "general", name = arg,
        provenance = { sourceChar = tostring(name) .. "-" .. tostring(realm), build = select(2, GetBuildInfo()) } }, modules)
    if not e then Print("Not saved: " .. tostring(err)) return end
    local n = 0
    for _ in pairs(modules.actions) do n = n + 1 end
    Print(("Saved %q (%d slots, bindings, %d character macros)."):format(e.name, n,
        (function() local c = 0; for _ in pairs(modules.macros) do c = c + 1 end; return c end)()))
end

function Commands.save()
    Print("Save over an existing loadout is disabled until #28 lands; use /altsync saveas <name>.")
end

function Commands.list()
    local list = ASS.Catalog.List("loadout", PlayerClass(), "general")
    if #list == 0 then Print("No saved General loadouts for this class yet. /altsync saveas <name>") return end
    for _, e in ipairs(list) do Print("  " .. tostring(e.name) .. (e.conflict and " (conflict)" or "")) end
end

function Commands.load(arg)
    local entry = FindLoadout(arg)
    if not entry then Print("No loadout named " .. tostring(arg) .. ". /altsync list") return end
    local plan = ASS.Loadout.Plan(entry)
    local lines = Commands.Describe(plan)
    local pinned = ASS.Backups.Operation()
    if pinned and not plan.blocked then
        table.insert(lines, 1, ("Abandon the incomplete load of %s? Its backup stays in your backups."):format(
            tostring(pinned.op and pinned.op.name)))
    end
    ASS.Preview.Show({
        title = "Load " .. tostring(entry.name) .. "?",
        lines = lines,
        -- A no-op still gets "Done": it records what was loaded (docs/DESIGN.md:
        -- a no-op Load records the baseline) without writing game state.
        confirm = plan.blocked and false or (plan.noop and "Done" or "Load"),
        onConfirm = function() Report("load", ASS.Loadout.Load(entry, plan, pinned ~= nil)) end,
    })
end

function Commands.backups()
    local ring, op, first = ASS.Backups.List()
    if op then Print(("  op: incomplete %s (%s)"):format(tostring(op.op and op.op.name), date and date("%Y-%m-%d %H:%M", op.snapshot.at) or "")) end
    for i, s in ipairs(ring) do Print(("  %d: %s"):format(i, tostring(s.reason))) end
    if first then Print("  first: the first snapshot for this character") end
    if not op and #ring == 0 then Print("No backups yet.") end
end

function Commands.restore(arg)
    local which = (arg == "" or arg == nil) and 1 or arg
    local plan = ASS.Loadout.PlanRestore(which)
    ASS.Preview.Show({
        title = "Restore backup " .. tostring(which) .. "?",
        lines = Commands.Describe(plan),
        confirm = (plan.blocked or plan.noop) and false or "Restore",
        onConfirm = function() Report("restore", ASS.Loadout.Restore(which, plan)) end,
    })
end

Commands.Report = Report
