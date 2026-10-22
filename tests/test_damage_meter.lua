dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")
local U=WoW.ui
local A,S,M,B
local function boot(opts)
    WoW.reset()
    for _,f in ipairs({"Core","Categories","Catalog","Game","Pet","Backups","Ready","Loadout","DamageMeter","UISetup","Commands"}) do
        assert(loadfile(f..".lua"))("AltStableSync",{})
    end
    WoW.fire("ADDON_LOADED","AltStableSync")
    A=AltStableSync; S=A.UISetup; M=A.DamageMeter; B=A.Backups
    WoW.game.setup{class="MAGE",guid="Player-70-METER",spells={{id=133,name="Fireball"}}}
    U.setup(); U.meterSetup(opts)
    WoW.fire("PLAYER_ENTERING_WORLD",true,false); WoW.clock=WoW.clock+10
end
local function part()
    return {windows={{meterType=0,sessionType=1,locked=true},{meterType=2,sessionType=1,locked=true}}}
end
local function entry(p)
    return assert(A.Catalog.Create("ui",{name="Meter"},{damageMeter=p or part()}))
end
local function apply(e) return S.Apply(e,S.Plan(e)) end
local function window(i) return U.meter[i] and U.meter[i].sessionWindow end
local function restore(which) return S.Restore(which,S.PlanRestore(which)) end

boot()
local captured,notes=S.Capture()
check("captures fresh nil lock", captured.damageMeter and captured.damageMeter.windows[1].locked==false)
eq("capture defaults healing",captured.damageMeter.windows[2].meterType,2)
eq("capture current",captured.damageMeter.windows[1].sessionType,1)
eq("capture never writes",#U.calls,0)
local e=entry()
local p=S.Plan(e)
check("preview second window",table.concat(S.Describe(p),"\n"):find("window 2",1,true))
eq("plan never writes",#U.calls,0)
local r=apply(e)
check("apply completed",r and not r.failed)
eq("window 2 created",U.count("MeterOpen"),1)
eq("window 1 current",window(1).sessionType,1)
eq("window 2 healing",window(2).meterType,2)
eq("window 2 current",window(2).sessionType,1)
check("locks applied",window(1).locked and window(2).locked)
check("no pin on complete",not B.Operation())
check("ring ownership",B.Get(1).damageMeter.journal.opened)
check("first ownership",B.Get("first").damageMeter.journal.opened)
r=restore(1)
check("restore completed",r and not r.failed and not r.partial)
eq("restore overall",window(1).sessionType,0)
eq("restore nil lock equivalent",window(1).locked,false)
check("restore hides our second",not window(2).shown)
r=restore(1)
check("undo restore completed",r and not r.failed and not r.partial)
check("undo restore reopens",window(2).shown)
eq("undo restore current",window(1).sessionType,1)

for _,which in ipairs({"first",1}) do
    boot(); e=entry(); apply(e)
    -- Independent copies model SavedVariables losing shared table identity.
    A.db.backups=A.Catalog.Copy(A.db.backups)
    local store=A.db.backups["Player-70-METER"]
    store.firstSeen=A.Catalog.Copy(store.firstSeen)
    r=restore(which)
    check("serialized ownership "..tostring(which),r and not r.partial and not window(2).shown)
end

boot(); e=entry(); p=S.Plan(e)
window(1).locked=true; U.meter[1].locked=true
local result,why=S.Apply(e,p)
check("stale preview refused",not result and why:find("changed",1,true))
eq("stale no writes",#U.calls,0)

boot(); e=entry()
local savedPin=B.Pin; B.Pin=function() return nil,"failed backup" end
result=apply(e)
check("backup failure aborts",not result)
eq("backup failure no writes",#U.calls,0)
B.Pin=savedPin

boot(); e=entry()
U.after.MeterOpen=function() error("after Show") end
r=apply(e)
check("open throw stops",r.failed and B.Operation())
check("open throw owns shown frame",B.Get("op").damageMeter.journal.opened and B.Get("first").damageMeter.journal.opened)
U.after.MeterOpen=nil
r=restore("op")
check("open throw restore",not r.partial and not window(2).shown and not B.Operation())

boot(); e=entry()
U.after.MeterOpen=function() U.meterShownFail=true end
r=apply(e)
check("unreadable open pins",r.failed and B.Operation())
U.meterShownFail=false
r=restore("op")
check("uncertain ownership partial",r.partial and B.Operation() and window(2).shown)
eq("uncertain ownership no hide",U.count("MeterHide"),0)
window(2).shown=false -- player closed it after the failed operation
r=restore("op")
check("uncertain opening stays partial after manual hide",r.partial and B.Operation())

boot(); e=entry()
U.meterManagerOnly=true
r=apply(e)
check("independent readback stops",r.failed and B.Operation())

boot(); e=entry()
U.after.MeterSession=function() U.meterReadFail=true end
r=apply(e)
check("failed getter stops",r.failed and B.Operation())
eq("failed getter no lock",U.count("MeterLock"),0)

boot(); e=entry()
DamageMeter.SetSessionWindowLocked=nil
p=S.Plan(e)
check("missing API skipped",p.noop and #p.skips==1 and p.skips[1].reason:find("not supported",1,true))
apply(e); eq("missing API no writes",#U.calls,0)

boot(); e=entry()
window(1).sessionID=77; window(1).sessionType=nil
U.meter[1].sessionID=77; U.meter[1].sessionType=nil
p=S.Plan(e)
check("specific encounter skipped",p.noop and p.skips[1].reason:find("Current or Overall",1,true))
apply(e); eq("encounter no writes",#U.calls,0)

boot({[3]={damageMeterType=2,sessionType=0,shown=false}}); e=entry()
p=S.Plan(e)
check("allocator 3 skipped",p.noop and #p.skips==1)
apply(e); eq("allocator no writes",#U.calls,0)

boot({[2]={damageMeterType=2,sessionType=0},[3]={damageMeterType=2,sessionType=0}}); e=entry()
local third=A.Catalog.Copy(U.meter[3])
apply(e); r=restore(1)
check("preexisting second stays shown",not r.partial and window(2).shown)
eq("preexisting second exact type",window(2).meterType,2)
eq("third session untouched",window(3).sessionType,0)
eq("preexisting second never hidden",U.count("MeterHide"),0)

for _,callName in ipairs({"MeterSession","MeterLock","MeterOpen","MeterType"}) do
    boot(); e=entry()
    U.after[callName]=function() WoW.game.combat=true end
    r=apply(e)
    check("combat stops after "..callName,r and r.failed and B.Operation())
    eq("last write before combat "..callName,U.calls[#U.calls],callName)
end

boot(); e=entry()
local oldRead=window(1).IsLocked
window(1).IsLocked=function() error("read") end
p=S.Plan(e)
check("nil distinct from getter exception",p.noop and #p.skips==1)
window(1).IsLocked=oldRead
issecretvalue=function(v) return v=="SECRET" end
window(1).locked="SECRET"
p=S.Plan(e)
check("secret skip",p.noop and #p.skips==1)
issecretvalue=nil

-- Geometry and hidden-frame setup reset, including exact undo.
boot({[2]={damageMeterType=2,sessionType=0,shown=false}})
local before=assert(M.Read()).windows[2].geometry
e=entry(); r=apply(e); check("hidden frame opened",not r.failed)
r=restore(1)
check("hidden frame restored",not r.partial and not window(2).shown)
eq("hidden frame x restored",window(2).x,before.x)
eq("hidden frame y restored",window(2).y,before.y)

for _,callName in ipairs({"MeterSize","MeterPoint","MeterPlaced"}) do
    boot({[2]={damageMeterType=2,sessionType=1}})
    local target=part(); target.windows[2].geometry={x=250,y=400,width=450,height=220,userPlaced=true}
    e=entry(target)
    U.after[callName]=function() WoW.game.combat=true end
    r=apply(e)
    -- The last placement write may finish successfully; any next write must stop.
    check("geometry guarded "..callName,r and (r.failed or callName=="MeterPlaced"))
    eq("geometry last write "..callName,U.calls[#U.calls],callName)
end

boot({[2]={damageMeterType=2,sessionType=1}})
local target=part(); target.windows[2].geometry={x=250,y=400,width=450,height=220,userPlaced=true}
target.future="keep"; target.windows[1].future="keep"; target.windows[2].geometry.future="keep"
e=entry(target); r=apply(e)
check("geometry applies",not r.failed)
eq("geometry x",window(2).x,250)
eq("geometry width",window(2).width,450)
window(2).x=300
local save=S.PlanSave()
check("save unknown part field",save.modules.damageMeter.future=="keep")
check("save unknown window field",save.modules.damageMeter.windows[1].future=="keep")
check("save unknown geometry field",save.modules.damageMeter.windows[2].geometry.future=="keep")
eq("save capture placement",save.modules.damageMeter.windows[2].geometry.x,300)

for _,mutate in ipairs({
    function(t) t.windows[1].locked=0 end,
    function(t) t.windows[2].meterType=0/0 end,
    function(t) t.windows[2].sessionType=0 end,
    function(t) t.windows[2].sessionID=55 end,
    function(t) t.windows[1]=nil end,
    function(t) t.windows[2].geometry={x=0,y=0,width=0,height=200,userPlaced=false} end,
}) do
    local bad=part(); mutate(bad)
    check("catalog rejects malformed meter",not A.Catalog.GoodUIModules({damageMeter=bad}))
end

boot(); e=entry()
local initialCalls=#U.calls
WoW.fire("PLAYER_ENTERING_WORLD",true,false); WoW.fire("PLAYER_REGEN_ENABLED")
WoW.clock=WoW.clock+10
eq("events never apply meter",#U.calls,initialCalls)
local saveAs=S.PlanSaveAs()
check("Save As fifth part",saveAs.modules.damageMeter ~= nil)
eq("Save As preview read only",#U.calls,initialCalls)
local newEntry=S.SaveAs(saveAs,"Captured")
check("Save As stores fifth part",newEntry.modules.damageMeter ~= nil)
eq("Save As does not apply",#U.calls,initialCalls)

boot(); e=entry()
e.modules.layout={type=1,name="My UI"}
U.after.SetActiveLayout=function() window(1).locked=true; U.meter[1].locked=true end
r=apply(e)
check("recheck after earlier UI write",r.failed and B.Operation())
eq("recheck before meter writes",U.count("MeterSession"),0)

boot(); e=entry(); apply(e)
local ring=B.PushRing; B.PushRing=function() return nil,"backup failed" end
local calls=#U.calls
result=restore(1)
check("restore backup must succeed",not result)
eq("restore backup failed no writes",#U.calls,calls)
B.PushRing=ring

boot(); e=entry(); apply(e)
B.Get(1).damageMeter.journal.opened=nil
r=restore(1)
check("restore requires proof",r.partial and window(2).shown)
eq("no ownership no hide",U.count("MeterHide"),0)

boot({[2]={damageMeterType=2,sessionType=0,shown=false}}); e=entry()
U.meter[2].sessionWindow=nil
p=S.Plan(e)
check("hidden data without frame skipped",p.noop and #p.skips==1)

boot(); e=entry()
window(1).shown=false
p=S.Plan(e)
check("hidden primary never opens wrong window",p.noop and #p.skips==1)

boot(); local future=part(); future.windows[2].meterType=999
e=entry(future); r=apply(e)
check("future type skipped",r.noop and #r.skips==1)
local saved=S.PlanSave()
eq("Save preserves future type",saved.modules.damageMeter.windows[2].meterType,999)

boot(); e=entry(); apply(e)
U.meterReadFail=true
saved=S.PlanSave()
eq("failed capture preserves intent",saved.modules.damageMeter.windows[2].meterType,2)

-- Code runs with read-only Blizzard global slots throughout capture/apply/restore.
boot()
local writes={}
local protected={DamageMeter=true,DamageMeterPerCharacterSettings=true,DamageMeterSessionWindow1=true,DamageMeterSessionWindow2=true}
local env=setmetatable({}, {__index=_G,__newindex=function(t,k,v)
    if protected[k] then writes[#writes+1]=k end
    rawset(t,k,v)
end})
env._G=env
env.rawset=function(t,k,v) if t==env and protected[k] then writes[#writes+1]=k end return rawset(t,k,v) end
local chunk=assert(loadfile("DamageMeter.lua")); setfenv(chunk,env); chunk()
e=entry(); apply(e); restore(1)
eq("no Blizzard global assignments",#writes,0)

boot(); e=entry()
local meterPlan=M.Plan(e.modules.damageMeter)
window(1).locked=true; U.meter[1].locked=true
check("snapshot must match preview",M.Snapshot(meterPlan)==nil)

boot(); e=entry()
U.after.MeterOpen=function() window(2).IsShown=function() return nil end end
r=apply(e)
check("nil visibility is not hidden",r.failed and B.Get("op").damageMeter.journal.uncertain)

boot({[2]={damageMeterType=2,sessionType=0}}); e=entry()
apply(e)
check("backup only touched geometry",B.Get(1).damageMeter.windows[2].geometry==nil)
window(2).x=350
restore(1)
eq("configuration restore leaves untouched geometry",window(2).x,350)

boot(); e=entry(); apply(e)
window(2).GetRect=function() return nil end
r=restore(1)
check("hide needs undoable geometry",r.partial and window(2).shown)

boot(); e=entry()
local bad=part(); bad.windows[1].locked="bad"
check("create validates meter",not A.Catalog.Create("ui",{name="Bad"},{damageMeter=bad}))
check("replace validates meter",not A.Catalog.Replace(e.id,{damageMeter=bad},e.version))
local incoming=A.Catalog.Copy(e); incoming.modules.damageMeter=bad
local status=A.Catalog.Upsert(incoming,"Other")
check("receipt validates meter",status==nil)

boot({[2]={damageMeterType=2,sessionType=1}})
target=part(); target.windows[2].geometry={x=1800,y=500,width=400,height=200,userPlaced=true}
e=entry(target); p=S.Plan(e)
check("offscreen geometry visibly skipped",#p.skips==1)
apply(e)
eq("offscreen geometry not written",U.count("MeterPoint"),0)
saved=S.PlanSave()
eq("skipped placement retained",saved.modules.damageMeter.windows[2].geometry.x,1800)

boot({[2]={damageMeterType=2,sessionType=0}})
target=part(); target.windows[2].geometry={x=250,y=400,width=450,height=220,userPlaced=true}
e=entry(target)
U.after.MeterSize=function() window(2).width=400 end
r=apply(e)
check("size readback required",r.failed and B.Operation())
eq("failed size stops before position",U.count("MeterPoint"),0)

boot()
B.Pin({kind="ui",meter={windows={}}},{kind="ui",name="Earlier draft"})
r=restore("op")
check("draft backup remains unavailable and pinned",r.partial and B.Operation())
eq("draft backup never writes",#U.calls,0)

finish("damage meter")
