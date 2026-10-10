------------------------------------------------------------
-- Commands.lua - /altsync commands for the #4 slice (until #9's panel)
--
--   /altsync saveas <name>   Save As: a new loadout in this class's "general"
--   /altsync save [drop]     Save over the loaded loadout (#28), previewed
--   /altsync list            this class's loadouts, every category, with ids
--   /altsync load <id|name>  preview, then load (writes only on confirm)
--   /altsync backups         this character's snapshots
--   /altsync restore [n|op]  preview, then restore exactly (default: newest)
--   /altsync rename <id|name> <new name>, delete <id|name>   catalog only, previewed
--   /altsync conflicts, resolve <id|name> theirs|mine   catalog only, previewed
--   /altsync status          (and /altsync link, from AltStableSyncLink)
-- An entry is named by its id, or by its name when exactly one entry has it:
-- sync can bring two entries with one name (docs/DESIGN.md "Catalog sync").
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

local function Trim(s) return ASS.Catalog.Trim(s) end

-- This class's live entry with id `arg`, or the one entry named `arg`; else
-- nil plus the lines to print (none found, or the candidates with their ids).
local function FindEntry(arg)
    arg = Trim(arg)
    local all = ASS.Catalog.ListAll("loadout", PlayerClass())
    for _, e in ipairs(all) do if e.id == arg then return e end end
    local want, found = arg:lower(), {}
    for _, e in ipairs(all) do
        if tostring(e.name):lower() == want then found[#found + 1] = e end
    end
    if #found == 1 then return found[1] end
    if #found == 0 then return nil, { ("No loadout named %q for this class. /altsync list"):format(arg) } end
    local lines = { ("%d loadouts are named %q; use the id:"):format(#found, arg) }
    for _, e in ipairs(found) do lines[#lines + 1] = "  " .. e.id end
    return nil, lines
end

-- A catalog change succeeded: say so, and say if the other account won't
-- hear of it because Link is off (#39). Nothing without the Link addon.
local function Changed(msg)
    Print(msg)
    local note = ASS.Link and ASS.Link.OffNote and ASS.Link.OffNote()
    if note then Print(note) end
end

local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- Catalog and Backups return short codes; this is the copy the player sees.
local COPY = {
    ["name-empty"] = "Give it a name: /altsync saveas <name>.",
    ["name-duplicate"] = "This class already has a loadout with that name. Pick another name.",
    ["incomplete"] = "An interrupted load is still pinned: /altsync restore op, or load again and abandon it.",
    ["no-guid"] = "Character data isn't available yet; try again in a moment.",
    ["stale"] = "It changed since the preview (perhaps from your other account). Review it again.",
    ["deleted"] = "That loadout was deleted.",
    ["unknown-id"] = "That loadout no longer exists.",
    ["conflict-copy"] = "That is a conflict copy: settle it with /altsync resolve.",
    ["not-conflict"] = "That conflict was already settled.",
    ["rename-empty"] = "Give it a name: /altsync rename <id or name> <new name>.",
    ["bad-modules"] = "Its saved data is damaged (no list of covered slots); nothing was changed.",
}
local function Copy(err) return COPY[err] or tostring(err) end

local function DescribeAction(a)
    if type(a) ~= "table" then return "empty" end
    if a.kind == "spell" then
        local name = C_Spell.GetSpellName and C_Spell.GetSpellName(a.id)
        return tostring(name or a.name or ("spell " .. tostring(a.id)))
    end
    if a.kind == "item" then return "item " .. tostring(a.id) end
    if a.kind == "macro" then return "macro " .. tostring(a.name) end
    return tostring(a.what or a.kind)
end

-- Per-slot lines grouped under one heading per bar with its count (#5),
-- ordered by slot. items = { { slot = n, text = "..." } }. Every line is kept:
-- the preview scrolls.
local function BySlot(lines, items)
    table.sort(items, function(a, b) return a.slot < b.slot end)
    for _, it in ipairs(items) do it.bar, it.button = ASS.Game.SlotLabel(it.slot) end
    local i = 1
    while i <= #items do
        local j = i
        while j < #items and items[j + 1].bar == items[i].bar do j = j + 1 end
        lines[#lines + 1] = ("  %s (%d):"):format(items[i].bar, j - i + 1)
        for k = i, j do
            local b = items[k].button
            lines[#lines + 1] = (b and ("    button %d: "):format(b) or "    ") .. items[k].text
        end
        i = j + 1
    end
end

-- The preview's lines for a plan (pure; tested).
function Commands.Describe(plan)
    local lines = {}
    if plan.blocked then return { plan.blocked } end
    -- Slots that stay empty until this character can use what the loadout
    -- has there (#46): listed, never counted as changes.
    local function Waiting(out)
        if #(plan.waiting or {}) == 0 then return end
        out[#out + 1] = "Stays empty until this character can use it:"
        local items = {}
        for _, w in ipairs(plan.waiting) do
            items[#items + 1] = { slot = w.slot, text = ("%s: %s"):format(DescribeAction(w.want), tostring(w.reason)) }
        end
        BySlot(out, items)
    end
    if plan.noop and not plan.keysBlocked and #(plan.unavailable or {}) == 0 and #plan.skips == 0 then
        local out = { "Already matches the selected settings." }
        if plan.kind == "restore" and #(plan.kept or {}) > 0 then
            out[#out + 1] = ("Kept: %s that load created (not deleted)."):format(Plural(#plan.kept, "macro"))
        end
        Waiting(out)
        return out
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
    local items = {}
    for _, op in ipairs(plan.actions) do
        local text = ("%s -> %s"):format(DescribeAction(op.current), DescribeAction(op.target))
        if op.why then text = ("%s (%s: %s)"):format(text, DescribeAction(op.want), op.why) end
        items[#items + 1] = { slot = op.slot, text = text }
    end
    BySlot(lines, items)
    local keys = {}
    for k, v in pairs(plan.keys) do keys[#keys + 1] = { k = k, v = v } end
    table.sort(keys, function(a, b) return a.k < b.k end)
    for _, kv in ipairs(keys) do
        lines[#lines + 1] = ("  %s: %s -> %s"):format(kv.k, kv.v.from or "unbound", kv.v.to or "unbound")
    end
    items = {}
    for _, s in ipairs(plan.skips) do items[#items + 1] = { slot = s.slot, text = "left unchanged: " .. tostring(s.reason) } end
    for _, u in ipairs(plan.unavailable or {}) do
        items[#items + 1] = { slot = u.slot, text = "can't be restored exactly: " .. tostring(u.reason) }
    end
    if #items > 0 then
        lines[#lines + 1] = "Not changed:"
        BySlot(lines, items)
    end
    Waiting(lines)
    if plan.kind == "restore" and #(plan.kept or {}) > 0 then
        lines[#lines + 1] = ("Kept: %s that load created (not deleted)."):format(Plural(#plan.kept, "macro"))
    end
    lines[#lines + 1] = plan.kind == "restore" and "Restore exact captured values. A backup is taken first."
        or "Backup first. Verify every write."
    return lines
end

-- `plan`: the confirmed plan, for what the result doesn't carry (#46: the
-- emptied and waiting slots; the saved result's shape stays as it is).
local function Report(kind, result, err, plan)
    if not result then
        Print((kind == "load" and "Not loaded: " or "Not restored: ") .. Copy(err))
        return
    end
    local waiting = plan and #(plan.waiting or {}) or 0
    if result.noop and not result.partial and #(result.skips or {}) > 0 then
        Print(("Nothing applied: %d left unchanged (see the preview's list)."):format(#result.skips))
        return
    end
    if result.noop and not result.partial and waiting > 0 then
        Print(("Already matches the loadout; %s stay%s empty until this character can use %s.")
            :format(Plural(waiting, "slot"), waiting == 1 and "s" or "", waiting == 1 and "it" or "them"))
        return
    end
    if result.noop and not result.partial then
        Print("Already matches the selected settings."
            .. (#(result.kept or {}) > 0 and (" Kept " .. Plural(#result.kept, "macro") .. " that load created.") or ""))
        return
    end
    if result.noop then
        Print("Nothing could be restored: see the preview's list. The backup is kept.")
        return
    end
    local skipped = #(result.skips or {}) + #(result.unavailable or {})
    if result.failed then
        local next_ = kind == "load"
            and "Use /altsync restore op to undo, or load again to abandon it."
            or "What was there before this restore is backup 1 in /altsync backups."
        Print(("Stopped (%s at %s): %d slots, %d keys done. %s")
            :format(result.failed, tostring(result.at), result.changed, result.keys, next_))
        return
    end
    local emptied = 0
    if kind == "load" and plan then
        for _, op in ipairs(plan.actions) do if op.target == nil then emptied = emptied + 1 end end
    end
    local msg = ("%s: %d slots%s, %d keys%s."):format(kind == "load" and "Loaded" or "Restored",
        result.changed, emptied > 0 and (" (" .. emptied .. " emptied)") or "",
        result.keys, result.created > 0 and (", " .. result.created .. " macros created") or "")
    if skipped > 0 then msg = msg .. " " .. skipped .. " left unchanged (see the preview's list)." end
    if result.partial then msg = msg .. " Partial: some entries couldn't be restored exactly; the backup is kept." end
    Print(msg)
end

local function Count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

-- Saves the plan `p` the player saw (or that needed no preview).
-- What a Save leaves out of a gap the loadout keeps for an action this
-- character can't use yet (#46), one line per slot.
local function Ignored(lines, ignored, actions)
    local items = {}
    for slot, c in pairs(ignored or {}) do
        items[#items + 1] = { slot = slot, text = ("holds %s now: not saved (the loadout keeps %s there)")
            :format(DescribeAction(c), DescribeAction(actions and actions[slot])) }
    end
    if #items == 0 then return end
    table.sort(items, function(x, y) return x.slot < y.slot end)
    lines[#lines + 1] = "Kept free for the loadout (load it again to change these slots):"
    BySlot(lines, items)
end

local function SaveAs(arg, p)
    local e, cerr = ASS.Loadout.SaveAs(p, arg)
    if not e then Print("Not saved: " .. Copy(cerr)) return end
    local msg = ("Saved %q (%d slots, bindings, %d character macros)."):format(e.name,
        Count(p.modules.actions), Count(p.modules.macros))
    if #p.kept > 0 then
        msg = msg .. (" Kept %s from the loaded setup that this character can't use."):format(
            Plural(#p.kept, "entry"):gsub("entrys", "entries"))
    end
    Changed(msg)
    for _, n in ipairs(p.notes) do Print(n) end
    local lines = {}
    Ignored(lines, p.ignored, p.modules.actions)
    for _, l in ipairs(lines) do Print(l) end
end

-- Save As keeps what the loaded setup had and this character can't use
-- (A09). Only when the last load left nothing to compare against, or the
-- merge refuses, does it become a plain capture, and then it says so first.
function Commands.saveas(arg)
    local p, err = ASS.Loadout.PlanSaveAs()
    if not p then Print("Not saved: " .. tostring(err)) return end
    if not p.lossy and (p.added or 0) == 0 then return SaveAs(arg, p) end
    local lines
    if p.lossy then
        lines = {
            p.why or "No usable comparison with the loaded setup (its load didn't finish, it was restored over, or it was loaded by an older version).",
            "Save As captures this character as it is now, and may leave out entries it inherited.",
        }
    else
        lines = {
            ("Adds %s the loaded setup didn't cover yet (%d with an action), from this character's bars."):format(
                Plural(p.added, "slot"), p.addedFull or 0),
            "Everything the loaded setup has is kept, as it would be on Save.",
        }
    end
    ASS.Preview.Show({
        title = "Save As " .. tostring(arg) .. "?",
        lines = lines,
        confirm = "Save As",
        -- The confirm saves what the preview showed, or nothing.
        onConfirm = function()
            local q, qerr = ASS.Loadout.PlanSaveAs()
            if not q then Print("Not saved: " .. tostring(qerr)) return end
            if ASS.Loadout.SaveAsFingerprint(q) ~= ASS.Loadout.SaveAsFingerprint(p) then
                Print("Not saved: Something changed since the preview: review it again.")
                return
            end
            SaveAs(arg, q)
        end,
    })
end

-- Save over the loaded loadout, keeping what this character can't use or
-- see (docs/DESIGN.md "Preserve intent on Save"). `drop`: those entries stop
-- being part of the loadout instead.
function Commands.save(arg)
    arg = Trim(arg or ""):lower()
    if arg ~= "" and arg ~= "drop" then Print("Usage: /altsync save [drop]") return end
    local drop = arg == "drop"
    local m, err = ASS.Loadout.PlanSave(drop)
    if not m then Print("Not saved: " .. tostring(err)) return end
    local name = tostring(m.entry.name)
    if m.noop then
        local lines = {}
        Ignored(lines, m.ignored, m.modules.actions)
        Print(#lines > 0 and ("No changes to save in %q."):format(name)
            or ("Already saved: %q matches this character."):format(name))
        for _, n in ipairs(m.notes) do Print(n) end
        for _, l in ipairs(lines) do Print(l) end
        return
    end
    local lines = { ("%s and %s change in %q."):format(Plural(#m.changed, "slot"), Plural(#m.keysChanged, "key"), name) }
    if (m.added or 0) > 0 then
        lines[#lines + 1] = ("Adds %s this loadout didn't cover yet (%d with an action, counted above)."):format(
            Plural(m.added, "slot"), m.addedFull or 0)
    end
    -- Each changed slot as "was -> now", so filling a slot the loadout keeps
    -- for a spell this character doesn't have yet shows what it replaces.
    local items = {}
    for _, slot in ipairs(m.changed) do
        local was, now = (m.before or {})[slot], m.modules.actions[slot]
        local text = ("%s -> %s"):format(DescribeAction(was), DescribeAction(now))
        if DescribeAction(was) == DescribeAction(now) then
            local why = "changed"
            if was and now and was.kind == "macro" and now.kind == "macro" then
                why = was.scope ~= now.scope and ("now a " .. (now.scope == "char" and "character" or "account") .. " macro")
                    or "macro text or icon changed"
            elseif was and now and was.kind == "spell" and now.kind == "spell" then
                why = "rank or rank policy changed"
            end
            text = ("%s (%s)"):format(DescribeAction(now), why)
        end
        items[#items + 1] = { slot = slot, text = text }
    end
    BySlot(lines, items)
    for _, cmd in ipairs(m.keysChanged) do
        local keys = m.modules.bindings and m.modules.bindings[cmd] or {}
        lines[#lines + 1] = ("  %s: %s"):format(cmd, #keys > 0 and table.concat(keys, ", ") or "unbound")
    end
    if #m.kept > 0 then
        lines[#lines + 1] = ("Keeping %s this character can't use:"):format(Plural(#m.kept, "entry"):gsub("entrys", "entries"))
        items = {}
        for _, k in ipairs(m.kept) do items[#items + 1] = { slot = k.slot, text = ("%s (%s)"):format(DescribeAction(k.want), k.reason) } end
        BySlot(lines, items)
        if not drop then lines[#lines + 1] = "To leave the unusable ones out instead: /altsync save drop" end
    end
    if #m.dropped > 0 then
        lines[#lines + 1] = "Won't be kept (a later Load empties these slots on every character):"
        items = {}
        for _, k in ipairs(m.dropped) do items[#items + 1] = { slot = k.slot, text = ("%s (%s)"):format(DescribeAction(k.want), k.reason) } end
        BySlot(lines, items)
    end
    Ignored(lines, m.ignored, m.modules.actions)
    for _, n in ipairs(m.notes) do lines[#lines + 1] = n end
    lines[#lines + 1] = "Other characters keep their current setup until they load this version."
    ASS.Preview.Show({
        title = "Update " .. name .. "?",
        lines = lines,
        confirm = "Save",
        onConfirm = function()
            local r, serr = ASS.Loadout.Save(m)
            if r then Changed(("Saved %q."):format(tostring(r.name)))
            else Print("Not saved: " .. Copy(serr)) end
        end,
    })
end

-- Every live conflict copy, in one pass: this class's loadouts (listed and
-- resolvable here), and one line counting the rest - other classes'
-- loadouts and UI setups - so none hides behind "No conflicts" (#39). With
-- the class not known yet, nothing is called "elsewhere".
local function SplitConflicts()
    local mine, here, by, n = PlayerClass(), {}, {}, 0
    if not mine then return here, nil end
    for _, e in ipairs(ASS.Catalog.Conflicts()) do
        if e.kind == "loadout" and e.class == mine then
            here[#here + 1] = e
        else
            local key = e.kind == "loadout" and tostring(e.class) or "ui"
            by[key] = (by[key] or 0) + 1
            n = n + 1
        end
    end
    if n == 0 then return here, nil end
    local names = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE or {}
    local parts = {}
    for key, k in pairs(by) do
        parts[#parts + 1] = ("%s (%d)"):format(key == "ui" and "UI setups" or names[key] or key, k)
    end
    table.sort(parts)
    return here, ("%d more not listed here: %s. Resolve a class's loadouts on a character of that class."):format(
        n, table.concat(parts, ", "))
end

local function Conflicts() return (SplitConflicts()) end

local function Marker(e, copies)
    if e.conflict then
        return e.conflict.deletion and (" (conflict: deleted on " .. tostring(e.conflict.from) .. ")") or " (conflict copy)"
    end
    if copies[e.id] then return " (conflict)" end
    local st = ASS.Link and ASS.Link.EntryStatus and ASS.Link.EntryStatus(e)
    return st and (" (" .. st .. ")") or ""
end

function Commands.list()
    local list = ASS.Catalog.ListAll("loadout", PlayerClass())
    if #list == 0 then Print("No saved loadouts for this class yet. /altsync saveas <name>") return end
    local copies = {}
    for _, c in ipairs(Conflicts()) do copies[c.conflict.of] = true end
    for _, e in ipairs(list) do
        local cat = ASS.Categories and ASS.Categories.Label(e.class, e.category) or tostring(e.category)
        Print(("  %s [%s] %s%s"):format(tostring(e.name), cat, e.id, Marker(e, copies)))
    end
end

Commands.SWITCH_LINES = {
    "This loadout sets key bindings, and this character uses your account keybindings.",
    "OK gives this character its own keybindings, starting as an exact copy of your account ones: "
        .. "the same as ticking Character Specific Keybindings in Settings.",
    "It also saves your current keys as your account keybindings, including changes not saved yet "
        .. "(for example by another addon).",
    "To go back, untick it in Settings; that deletes this character's keybindings.",
    "Step 2 shows what the load changes, with its own Load button.",
}

-- Step 2 of the #7 wizard: wait (display only) until planning is ready, then
-- show the ordinary Load preview. It stops if its own preview is no longer
-- on screen: cancelled, or replaced by another preview.
Commands.STEP2 = "Step 2 of 2. Character keybindings are on; cancelling leaves them on."
function Commands.AwaitLoad(id, name)
    local waiting = {
        title = ("Load %s: step 2 of 2"):format(name),
        lines = { "Character keybindings are on; cancelling leaves them on.",
                  "Waiting for your keybindings to settle..." },
        confirm = false,
    }
    ASS.Preview.Show(waiting)
    if not (C_Timer and C_Timer.After) then
        waiting.lines[2] = ("Run /altsync load %s to review and load it."):format(name)
        ASS.Preview.Show(waiting)
        return
    end
    local deadline = GetTime() + 10
    local function tick()
        if ASS.Preview.Shown() ~= waiting then return end      -- cancelled or replaced
        if ASS.Ready.IsReady() then
            ASS.Preview.Hide()
            local e = ASS.Catalog.Get(id)
            if not e or e.deleted then Print(Copy("unknown-id")) return end
            if not ASS.Game.CharacterBindings() then
                Print(("Character keybindings aren't on any more, so nothing was loaded. /altsync load %s to start again.")
                    :format(name))
                return
            end
            return Commands.load(id, Commands.STEP2)
        end
        if GetTime() >= deadline then
            waiting.lines[2] = ("Still waiting for character data. Run /altsync load %s when ready."):format(name)
            ASS.Preview.Show(waiting)
            return
        end
        C_Timer.After(0.5, tick)
    end
    C_Timer.After(0.5, tick)
end

-- `note`: a line shown first (step 2 of the #7 wizard).
function Commands.load(arg, note)
    local entry, why = FindEntry(arg)
    if not entry then for _, l in ipairs(why) do Print(l) end return end
    if type(entry.modules) ~= "table" then
        -- A deletion conflict copy stands for "deleted on the other account".
        Print("That entry has nothing to load. " .. Copy("conflict-copy")) return
    end
    local plan = ASS.Loadout.Plan(entry)
    if plan.needsCharacterBindings then
        -- #7, a two-step wizard: step 1's OK turns on character keybindings
        -- and nothing else; step 2 is the ordinary Load preview, planned
        -- afresh once the switch's UPDATE_BINDINGS has settled, with its own
        -- Load click.
        local id, name = entry.id, tostring(entry.name)
        ASS.Preview.Show({
            title = ("Load %s: step 1 of 2"):format(name),
            lines = Commands.SWITCH_LINES,
            confirm = "OK",
            onConfirm = function()
                local ok, why = ASS.Loadout.UseCharacterBindings()
                if not ok then Print(why) return end
                Commands.AwaitLoad(id, name)
            end,
        })
        return
    end
    local lines = Commands.Describe(plan)
    -- A no-op still gets "Done": it records what was loaded (docs/DESIGN.md: a
    -- no-op Load records the baseline) without writing game state.
    local confirm = "Load"
    if plan.blocked then confirm = false elseif plan.noop then confirm = "Done" end
    local pinned = ASS.Backups.Operation()
    if pinned and not plan.blocked then
        table.insert(lines, 1, ("Abandon the incomplete load of %s? Its backup stays in your backups."):format(
            tostring(pinned.op and pinned.op.name)))
    end
    if note then table.insert(lines, 1, note) end
    ASS.Preview.Show({
        title = "Load " .. tostring(entry.name) .. "?",
        lines = lines,
        confirm = confirm,
        onConfirm = function()
            local r, err = ASS.Loadout.Load(entry, plan, pinned ~= nil)
            Report("load", r, err, plan)
        end,
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
    local which = tostring(arg or ""):lower():match("^%s*(.-)%s*$")
    if which == "" then which = "1" end
    local plan = ASS.Loadout.PlanRestore(which)
    -- A fully matching restore of the pinned operation still gets "Done", so
    -- its completion can release the pin; any other no-op has nothing to do.
    local complete = #plan.unavailable == 0 and not plan.keysBlocked
    local confirm = "Restore"
    if plan.blocked then confirm = false
    elseif plan.noop then confirm = (which == "op" and complete) and "Done" or false end
    ASS.Preview.Show({
        title = "Restore backup " .. tostring(which) .. "?",
        lines = Commands.Describe(plan),
        confirm = confirm,
        onConfirm = function() Report("restore", ASS.Loadout.Restore(which, plan)) end,
    })
end

------------------------------------------------------------
-- Catalog-only commands: rename, delete, conflicts, resolve. Each is
-- previewed; the confirm passes the id and the version the preview showed,
-- and the catalog refuses if either account changed it since ("stale").
------------------------------------------------------------

function Commands.rename(arg)
    local key, name = tostring(arg or ""):match("^%s*(%S+)%s+(.-)%s*$")
    if not key then Print("Usage: /altsync rename <id or one-word name> <new name>  (see /altsync list)") return end
    -- An id, or a one-word name (a name with spaces needs the id).
    local e = ASS.Catalog.Get(key)
    if not e or e.deleted or e.kind ~= "loadout" or e.class ~= PlayerClass() then
        local why
        e, why = FindEntry(key)
        if not e then for _, l in ipairs(why) do Print(l) end return end
    end
    if e.conflict then Print(Copy("conflict-copy")) return end
    local trimmed, nerr = ASS.Catalog.ValidateName(e.kind, e.class, e.category, name, e.id)
    if not trimmed then Print("Not renamed: " .. Copy(nerr == "name-empty" and "rename-empty" or nerr)) return end
    name = trimmed
    local version = e.version
    ASS.Preview.Show({
        title = "Rename " .. tostring(e.name) .. "?",
        lines = { ("%q becomes %q. Nothing on any character changes."):format(tostring(e.name), name) },
        confirm = "Rename",
        onConfirm = function()
            local r, err = ASS.Catalog.Rename(e.id, name, version)
            if r then Changed(("Renamed to %q."):format(r.name))
            else Print("Not renamed: " .. Copy(err == "name-empty" and "rename-empty" or err)) end
        end,
    })
end

function Commands.delete(arg)
    local e, why = FindEntry(arg)
    if not e then for _, l in ipairs(why) do Print(l) end return end
    if e.conflict then Print(Copy("conflict-copy")) return end
    local id, version = e.id, e.version
    ASS.Preview.Show({
        title = "Delete " .. tostring(e.name) .. "?",
        lines = { ("%q leaves the list on both accounts. Nothing on any character changes; "
            .. "backups stay."):format(tostring(e.name)) },
        confirm = "Delete",
        onConfirm = function()
            local r, err = ASS.Catalog.Delete(id, version)
            if r then Changed(("Deleted %q."):format(tostring(r.name)))
            else Print("Not deleted: " .. Copy(err)) end
        end,
    })
end

function Commands.conflicts()
    local list, others = SplitConflicts()
    if #list == 0 then
        Print(others and "No conflicts for this class." or "No conflicts.")
    else
        for _, c in ipairs(list) do Print(("  %s: %s"):format(c.id, tostring(c.name))) end
        Print("Settle each with /altsync resolve <id> theirs or mine")
    end
    if others then Print(others) end
end

-- `resolve <id|name> theirs|mine`. For a deletion made on the other account,
-- "theirs" means delete here too.
function Commands.resolve(arg)
    local target, choice = tostring(arg or ""):match("^%s*(.-)%s+(%S+)%s*$")
    choice = choice and choice:lower()
    if not target or (choice ~= "theirs" and choice ~= "mine") then
        Print("Usage: /altsync resolve <id or name> theirs or mine  (see /altsync conflicts)") return
    end
    local copy, why = FindEntry(target)
    if not copy then for _, l in ipairs(why) do Print(l) end return end
    if not copy.conflict then
        -- The root named: its one open copy, or the choice of copies.
        local copies = {}
        for _, c in ipairs(Conflicts()) do if c.conflict.of == copy.id then copies[#copies + 1] = c end end
        if #copies == 0 then Print(Copy("not-conflict")) return end
        if #copies > 1 then
            Print(("%q has %d conflict copies; resolve each by its id:"):format(tostring(copy.name), #copies))
            for _, c in ipairs(copies) do Print("  " .. c.id .. ": " .. tostring(c.name)) end
            return
        end
        copy = copies[1]
    end
    local root = ASS.Catalog.Get(copy.conflict.of)
    if not root then Print(Copy("unknown-id")) return end
    local from = tostring(copy.conflict.from or "your other account")
    local name = tostring(copy.conflict.name or root.name)
    local deletion = copy.conflict.deletion
    local apiChoice = (deletion and choice == "theirs") and "delete" or choice
    local line
    if deletion and root.deleted then
        line = ("%q is deleted on both accounts; it stays deleted."):format(name)
    elseif deletion then
        line = choice == "theirs" and ("Delete %q here too, as %s did."):format(name, from)
            or ("Keep %q (deleted on %s); it comes back there too."):format(name, from)
    elseif root.deleted then
        line = choice == "theirs" and ("Keep the version from %s as a new loadout; the deleted one stays deleted."):format(from)
            or ("Keep it deleted; the version from %s is dropped on both accounts."):format(from)
    else
        line = choice == "theirs" and ("Use the version from %s for %q on both accounts."):format(from, name)
            or ("Keep this account's %q on both accounts; the version from %s is dropped."):format(name, from)
    end
    local copyId, rootVersion = copy.id, root.version
    ASS.Preview.Show({
        title = "Resolve " .. name .. "?",
        lines = { line, "Only the saved list changes; nothing on any character changes." },
        confirm = "Resolve",
        onConfirm = function()
            local r, err = ASS.Catalog.Resolve(copyId, apiChoice, rootVersion)
            if r then Changed("Resolved.") else Print("Not resolved: " .. Copy(err)) end
        end,
    })
end

Commands.Report = Report
