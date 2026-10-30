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

-- Forever's measured placement surface lacks the three getters, while
-- retaining rectangle setters. Do not invent or write a userPlaced flag.
boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
local w=window(2)
w.point,w.relativePoint="TOPLEFT","TOPLEFT"
w.x,w.y,w.width,w.height=40,960,400,199.99995422363
w.GetEffectiveScale=function() return 0.63999998569489 end
UIParent.GetEffectiveScale=w.GetEffectiveScale
UIParent.GetWidth=function() return 2133.3334960938 end
UIParent.GetHeight=function() return 1200 end
local capturedPart,note=M.Capture()
check("Forever rectangle captured",capturedPart.windows[2].geometry ~= nil)
eq("Forever height preserved",capturedPart.windows[2].geometry.height,199.99995422363)
eq("Forever unknown flag omitted",capturedPart.windows[2].geometry.userPlaced,nil)
check("Forever rectangle catalog accepted",A.Catalog.GoodUIModules({damageMeter=capturedPart}))
capturedPart.windows[2].geometry.x=1400
capturedPart.windows[2].geometry.y=300
e=entry(capturedPart)
w.userPlaced=true -- internal to the stub, intentionally unreadable to addon
r=apply(e)
check("Forever rectangle applied",r and not r.failed)
eq("Forever x applied",w.x,1400)
eq("Forever y applied",w.y,300)
eq("Forever flag never written",U.count("MeterPlaced"),0)
check("Forever existing flag untouched",w.userPlaced)
r=restore(1)
check("Forever rectangle restored",r and not r.partial)
eq("Forever x restored",w.x,40)
check("Forever y restored",math.abs(w.y-960)<.05)
eq("Forever restore flag never written",U.count("MeterPlaced"),0)

boot({forever=true})
target=part(); target.windows[2].geometry={x=400,y=300,width=400,height=200}
e=entry(target); r=apply(e)
check("Forever new window positioned",r and not r.failed and window(2).x==400)
eq("Forever new window flag never written",U.count("MeterPlaced"),0)
r=restore(1)
check("Forever unknown flag prevents undoable hide",r.partial and window(2).shown)
eq("Forever unknown flag no hide write",U.count("MeterHide"),0)

boot({forever=true,[2]={damageMeterType=2,sessionType=0,shown=false}})
e=entry(); p=S.Plan(e)
check("Forever hidden existing window skips reset",p.noop and #p.skips==1)
apply(e)
eq("Forever hidden existing never reopened",U.count("MeterOpen"),0)

boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
target=part(); target.windows[2].geometry={x=400,y=300,width=400,height=200,userPlaced=true}
e=entry(target); p=S.Plan(e)
check("explicit unreadable flag intent skipped",#p.skips==1)
apply(e)
eq("explicit unreadable flag never written",U.count("MeterPlaced"),0)
saved=S.PlanSave()
eq("explicit flag intent kept on Save",saved.modules.damageMeter.windows[2].geometry.userPlaced,true)

for _,mouse in ipairs({"down","throw","nil","malformed","absent"}) do
    boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
    if mouse=="down" then U.mouseDown=true
    elseif mouse=="throw" then IsMouseButtonDown=function() error("unreadable") end
    elseif mouse=="nil" then IsMouseButtonDown=function() return nil end
    elseif mouse=="malformed" then IsMouseButtonDown=function() return 0 end
    else IsMouseButtonDown=nil end
    capturedPart=M.Capture()
    check("mouse fallback fails closed: "..mouse,not capturedPart.windows[2].geometry)
end

boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
target=part(); target.windows[2].geometry={x=400,y=300,width=450,height=200}
e=entry(target)
U.after.MeterSize=function() U.mouseDown=true end
r=apply(e)
check("mouse starts during writes stops",r.failed and B.Operation())
eq("mouse stops before point write",U.count("MeterPoint"),0)

for _,getter in ipairs({"IsMinimized","IsResizing","IsUserPlaced"}) do
    boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
    window(2)[getter]=function() error("failed read") end
    capturedPart=M.Capture()
    check("present getter failure still rejected: "..getter,not capturedPart.windows[2].geometry)
end

boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
window(2).height=25
capturedPart=M.Capture()
check("collapsed rectangle rejected without minimized getter",not capturedPart.windows[2].geometry)

-- A rectangle-only entry does not acquire a flag write on a fuller client.
boot({[2]={damageMeterType=2,sessionType=1}})
window(2).userPlaced=true
target=part(); target.windows[2].geometry={x=400,y=300,width=450,height=200}
e=entry(target); r=apply(e)
check("rectangle-only entry on full client",not r.failed)
eq("rectangle-only backup omits untouched flag",B.Get(1).damageMeter.windows[2].geometry.userPlaced,nil)
eq("rectangle-only apply no flag write",U.count("MeterPlaced"),0)
r=restore(1)
check("rectangle-only restore on full client",not r.partial)
eq("rectangle-only restore no flag write",U.count("MeterPlaced"),0)
check("rectangle-only flag retained",window(2).userPlaced)

boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
target=part(); target.windows[2].geometry={x=400,y=300,width=450,height=200}
e=entry(target)
local originalPoint=window(2).GetPoint
local readsAfterSize=0
window(2).GetPoint=function(self)
    if U.count("MeterSize")>0 then
        readsAfterSize=readsAfterSize+1
        if readsAfterSize==2 then U.mouseDown=true end
    end
    return originalPoint(self)
end
r=apply(e)
check("mouse rechecked immediately before point write",r.failed and B.Operation())
eq("mouse down after geometry read prevents point write",U.count("MeterPoint"),0)

boot({forever=true}); e=entry()
U.after.MeterOpen=function() error("opened then stopped") end
r=apply(e)
check("Forever opening failure pinned",r.failed and B.Operation())
U.after.MeterOpen=nil
r=restore("op")
check("Forever partial visibility restore retains pin",r.partial and B.Operation() and window(2).shown)

boot({forever=true,[2]={damageMeterType=2,sessionType=1,locked=true}})
e=entry(); apply(e)
local captureNote
window(2).GetPoint=function() return "TOPLEFT",{},"TOPLEFT" end
capturedPart,captureNote=M.Capture()
check("capture explains rejected anchor",captureNote:find("anchor is not relative to the screen or UIParent",1,true))
eq("failed geometry still captures lock",capturedPart.windows[2].locked,true)
check("diagnostic not stored in window state",M.Read().windows[3]==nil)
window(2).GetPoint=function() return "TOPLEFT",UIParent,"TOPLEFT" end
U.mouseDown=true
capturedPart,captureNote=M.Capture()
check("capture explains mouse guard",captureNote:find("left button is held",1,true))
U.mouseDown=false
window(2).GetRect=function() error("private runtime details") end
capturedPart,captureNote=M.Capture()
check("capture gives safe read failure reason",captureNote:find("rectangle or screen size cannot be read",1,true))
check("capture never exposes runtime exception text",not captureNote:find("private runtime details",1,true))

boot({forever=true,[2]={damageMeterType=2,sessionType=1,locked=true}})
e=entry(); apply(e)
w=window(2)
w.screenAnchor=true
w.point,w.relativePoint="BOTTOMRIGHT","BOTTOMRIGHT"
w.x,w.y=1400,300
saved=S.PlanSave()
check("screen anchor creates a Save change",not saved.noop and not saved.blocked)
eq("screen anchor Save captures x",saved.modules.damageMeter.windows[2].geometry.x,1400)
eq("screen anchor Save preserves lock",saved.modules.damageMeter.windows[2].locked,true)
check("screen anchor Save succeeds",S.Save(saved)~=nil)
e=A.Catalog.Get(e.id)
-- Change the live rectangle after saving. Apply must put it back, and its
-- backup must restore this screen-relative rectangle through a UIParent anchor.
w.x,w.y=900,200
local previousCalls=#U.calls
r=apply(e)
check("screen anchor applies saved rectangle",not r.failed)
eq("screen anchor applied x",w.x,1400)
eq("screen anchor applied y",w.y,300)
check("screen anchor rewritten through UIParent",not w.screenAnchor)
eq("screen anchor never changes unknown flag",U.count("MeterPlaced"),0)
r=restore(1)
check("screen anchor rectangle restored",not r.partial)
eq("screen anchor restored x",w.x,900)
eq("screen anchor restored y",w.y,200)
check("screen anchor performed guarded writes",#U.calls>previousCalls)

-- Accepting a screen anchor must not bypass the existing scale/bounds checks.
boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
w=window(2); w.screenAnchor=true
w.GetEffectiveScale=function() return 2 end
capturedPart=M.Capture()
check("screen anchor with different scale rejected",not capturedPart.windows[2].geometry)
w.GetEffectiveScale=function() return 1 end
w.x=-10
capturedPart=M.Capture()
check("screen anchor offscreen rejected",not capturedPart.windows[2].geometry)


-- Audit #95 D6: on Forever (no IsUserPlaced) opening window 2 can't be
-- undone, and with it the whole meter part: the apply preview says so, and
-- after the restore window 1 keeps the applied values too.
boot({forever=true})
e=entry(); p=S.Plan(e)
local text=table.concat(S.Describe(p),"\n")
check("D6 forever: preview says the restore leaves the meter as set",text:find("can't be hidden again",1,true)~=nil)
r=apply(e)
check("D6 forever: applied",r and not r.failed)
eq("D6 forever: window 1 locked by the apply",window(1).locked,true)
r=restore(1)
check("D6 forever: restore partial, window 2 shown",r.partial and window(2).shown)
eq("D6 forever: window 1 keeps the applied lock (whole part skipped)",window(1).locked,true)
eq("D6 forever: window 1 keeps the applied session",window(1).sessionType,1)
boot()
e=entry(); p=S.Plan(e)
check("D6 mainline: no such line",table.concat(S.Describe(p),"\n"):find("can't be hidden again",1,true)==nil)
boot({forever=true,[2]={damageMeterType=2,sessionType=1}})
e=entry(); p=S.Plan(e)
check("D6 forever, window 2 already shown: no such line",table.concat(S.Describe(p),"\n"):find("can't be hidden again",1,true)==nil)

finish("damage meter")
