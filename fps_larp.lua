local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local VIRTUAL_FPS = 400
local MAX_STEPS = 16
local EXTRA_MS = 4
local MAX_FRAME_SHARE = 0.15
local HOOK_RENDER_STEP = true
local RESCAN_SECONDS = 2
local DEBUG = false

if getgenv().FpsLarp then getgenv().FpsLarp() end
if getgenv().SkillVirtualFPS then getgenv().SkillVirtualFPS() end
if getgenv().RainbowAura then getgenv().RainbowAura() end

local genv = getgenv()
local SELF = debug.info(1, "s")
local STEP = 1 / VIRTUAL_FPS
local EXTRA_BUDGET = EXTRA_MS / 1000
local GAME_ROOTS = { "ReplicatedStorage", "ReplicatedFirst", "Players", "Workspace", "StarterPlayer", "StarterGui", "StarterPack", "Lighting", "SoundService" }
local EXCLUDED = {
    "Players." .. Players.LocalPlayer.Name .. ".PlayerScripts.PlayerModule",
    "ReplicatedStorage.Controllers.CameraController",
    "ReplicatedStorage.Util.CameraShake",
    "ReplicatedStorage.Util.CameraShakeOffset",
    "ReplicatedStorage.Util.CameraShaker",
    "ReplicatedStorage.Util.DeltaTime",
    -- Skull Guitar M1/tap: moves the notes by a fixed amount per call (not scaled by dt), so the budgeted
    -- sub-stepping ran them a different number of times every frame and they lurched. These are kept out of
    -- the generic path and get a steady sub-step count instead, see FIXED_STEP
    "ReplicatedStorage.EffectContainer.SoulGuitar.LeftClick",
    "ReplicatedStorage.EffectContainer.SoulGuitar.LeftClickImpact",
    -- the real HeartbeatLoopFor only runs for callers that were excluded above (allowed ones go through boostedLoop),
    -- but its connection would still be caught by the background rescan and sub-stepped despite the exclusion
    "ReplicatedStorage.Util.HeartbeatLoopFor",
}
-- HeartbeatLoopFor callers that run their callback exactly the same number of times every frame (about
-- VIRTUAL_FPS per second) and never skip steps for budget, so per-call effects look like real VIRTUAL_FPS and stay smooth
local FIXED_STEP = {
    ["ReplicatedStorage.EffectContainer.SoulGuitar.LeftClick"] = true,
    ["ReplicatedStorage.EffectContainer.SoulGuitar.LeftClickImpact"] = true,
}
local FRAME_SIGNALS = {
    ["Signal RenderStepped"] = "RenderStepped", ["Signal Heartbeat"] = "Heartbeat", ["Signal Stepped"] = "Stepped",
    ["Signal PreRender"] = "PreRender", ["Signal PreAnimation"] = "PreAnimation", ["Signal PreSimulation"] = "PreSimulation",
    ["Signal PostSimulation"] = "PostSimulation",
}
local SIGNAL_LIST = {}
for _, prop in pairs(FRAME_SIGNALS) do table.insert(SIGNAL_LIST, prop) end
local WAIT_KEYS = { Wait = true, wait = true }
local CONNECT_KEYS = { Connect = true, connect = true }
local AURA_SOURCE = "ReplicatedStorage.EffectContainer.RaceAwakenings.Skypiean"
local AURA_TEXTURE = "8271975883"
local AURA_LEVELS = 24
local AURA_WIDTH_FRACTION = 167 / 411
local AURA_CURVE_RES = 64
local AURA_SHAPE = { 0.096, 0.622, 0.82, 0.94, 1, 0.97, 0.887, 0.787, 0.689, 0.593, 0.509, 0.437, 0.365, 0.305, 0.25, 0.198, 0.151, 0.11, 0.072, 0.041, 0.006 }

local sourceVerdicts, conns, restores, bindings = {}, {}, {}, {}
local waitWrappers, connectWrappers = {}, {}
local hooked = setmetatable({}, { __mode = "k" })
local threads = setmetatable({}, { __mode = "k" })
local pendingAura = setmetatable({}, { __mode = "k" })
local enabled, spent, frameDt, frameId = true, 0, 1 / 60, 0
local smoothDt, fixedN = 1 / 60, 1
local frameBudget = math.min(EXTRA_BUDGET, frameDt * MAX_FRAME_SHARE)
local stats = { ran = 0, skipped = 0, boosts = 0, denied = 0, window = 0 }

table.insert(conns, RunService.PreRender:Connect(function(dt)
    spent = 0
    frameId += 1
    frameDt = dt
    smoothDt = smoothDt * 0.9 + math.min(dt, 0.05) * 0.1
    frameBudget = math.min(EXTRA_BUDGET, dt * MAX_FRAME_SHARE)
    if DEBUG then
        stats.window += dt
        if stats.window >= 2 then
            print(string.format("[fps larp] sub-steps ran %d, skipped %d | waits boosted %d, denied %d | budget %.1f ms/frame",
                stats.ran, stats.skipped, stats.boosts, stats.denied, frameBudget * 1000))
            stats.ran, stats.skipped, stats.boosts, stats.denied, stats.window = 0, 0, 0, 0, 0
        end
    end
end))

local function under(path, root)
    return path == root or string.sub(path, 1, #root + 1) == root .. "."
end

local function allowedSource(src)
    local verdict = sourceVerdicts[src]
    if verdict == nil then
        verdict = false
        for _, root in ipairs(GAME_ROOTS) do
            if under(src, root) then
                verdict = true
                break
            end
        end
        if verdict then
            for _, root in ipairs(EXCLUDED) do
                if under(src, root) then
                    verdict = false
                    break
                end
            end
        end
        sourceVerdicts[src] = verdict
    end
    return verdict
end

local function fnAllowed(fn)
    local src = debug.info(fn, "s")
    return src ~= nil and allowedSource(src)
end

local function callerSource()
    for level = 2, 10 do
        local src = debug.info(level, "s")
        if src == nil then return nil end
        if src ~= SELF and src ~= "[C]" then return src end
    end
    return nil
end

local function callerAllowed()
    local src = callerSource()
    return src ~= nil and allowedSource(src)
end

local function tryBoost()
    local th = coroutine.running()
    local now = os.clock()
    local st = threads[th]
    if not st then
        st = { budget = 0, last = now, debt = 0, cost = 0 }
        threads[th] = st
    end
    if st.boostedAt then
        -- only a same-frame return is real work. If the thread yielded somewhere else in between,
        -- charging that gap would burn the whole frame budget and starve every other callback
        if st.boostedFrame == frameId then
            local took = math.min(now - st.boostedAt, frameBudget)
            spent += took
            st.cost = st.cost * 0.7 + took * 0.3
        end
        st.boostedAt = nil
    end
    local gap = now - st.last
    if gap > frameDt * 2 + 0.005 then
        st.budget, st.debt = 0, 0
    else
        st.budget = math.min(st.budget + gap * VIRTUAL_FPS, MAX_STEPS)
    end
    st.last = now
    if enabled and st.budget >= 2 then
        if spent + st.cost < frameBudget then
            st.budget -= 1
            st.debt += STEP
            st.boostedAt, st.boostedFrame = os.clock(), frameId
            stats.boosts += 1
            return st, true
        end
        stats.denied += 1
        st.cost *= 0.9 -- no new sample while denied, so let the estimate fade or it would stay denied forever
    end
    st.budget = math.max(st.budget - 1, 0)
    return st, false
end

local function settle(st, dt)
    if type(dt) ~= "number" then return dt end
    local out = math.max(dt - st.debt, 1e-4)
    st.debt = math.max(st.debt - dt, 0)
    return out
end

local function connEnabled(cn)
    return cn.Enabled
end

-- meta = { fn, stepped, alive, carry, cost }. Runs fn several times per frame with a smaller dt.
local function step(meta, a, b, ...)
    local fn, stepped = meta.fn, meta.stepped
    local dt = stepped and b or a
    if not enabled or type(dt) ~= "number" or dt <= 0 then return fn(a, b, ...) end
    local carry = meta.carry + dt * VIRTUAL_FPS
    local steps = math.clamp(math.floor(carry), 1, MAX_STEPS)
    meta.carry = math.clamp(carry - steps, 0, MAX_STEPS)
    local want, cost = steps, meta.cost
    if cost > 0 then
        -- plan only as many sub-steps as what is left of the frame budget can pay for, so every
        -- call sees an even dt instead of a few tiny ones and then one huge leftover
        local afford = math.floor(math.max(frameBudget - spent, 0) / cost)
        if afford + 1 < steps then steps = afford + 1 end
    end
    local sub, given, alive, ran = dt / steps, 0, meta.alive, 0
    for _ = 2, steps do
        if spent >= frameBudget or not alive() then break end
        local t0 = os.clock()
        given += sub
        if stepped then fn(a - dt + given, sub) else fn(sub) end
        local took = os.clock() - t0
        spent += took
        cost = cost * 0.7 + took * 0.3
        ran += 1
    end
    stats.ran += ran
    if ran < want - 1 then
        stats.skipped += want - 1 - ran
        cost *= 0.95 -- nothing measured this frame, let the estimate fade so it gets probed again
    end
    meta.cost = cost
    if not alive() then return end
    if stepped then return fn(a, dt - given) end
    return fn(dt - given)
end

local function subStepped(fn, stepped, alive)
    local meta = { fn = fn, stepped = stepped, alive = alive, carry = 0, cost = 0 }
    return function(a, b, ...) return step(meta, a, b, ...) end
end

-- Wrappers handed to the engine (Connect / BindToRenderStep) outlive this run when the script is
-- executed again, so they call whichever run is current instead of this run's upvalues. A new run
-- then picks them up for free; before, they were left passing straight through at the real fps.
local function portable(fn, stepped, alive)
    local meta = { fn = fn, stepped = stepped, alive = alive, carry = 0, cost = 0 }
    return function(a, b, ...)
        local run = genv.FpsLarpStep
        if run then return run(meta, a, b, ...) end
        return fn(a, b, ...)
    end
end
genv.FpsLarpStep = step

local function wrapWait(method)
    local wrapper = waitWrappers[method]
    if not wrapper then
        wrapper = function(self, ...)
            if not enabled then return method(self, ...) end
            local st, boost = tryBoost()
            local stepped = tostring(self) == "Signal Stepped"
            if boost then
                if stepped then return workspace.DistributedGameTime, STEP end
                return STEP
            end
            if stepped then
                local t, dt = method(self, ...)
                return t, settle(st, dt)
            end
            return settle(st, method(self, ...))
        end
        waitWrappers[method] = wrapper
    end
    return wrapper
end

local function wrapConnect(method)
    local wrapper = connectWrappers[method]
    if not wrapper then
        wrapper = function(self, fn, ...)
            if not enabled or type(fn) ~= "function" or not fnAllowed(fn) then return method(self, fn, ...) end
            local conn
            conn = method(self, portable(fn, tostring(self) == "Signal Stepped", function()
                return conn == nil or conn.Connected
            end), ...)
            return conn
        end
        connectWrappers[method] = wrapper
    end
    return wrapper
end

local auras = {}
local auraFolder = Instance.new("Folder")
auraFolder.Name = "FpsLarpAura"
auraFolder.Parent = workspace.CurrentCamera
table.insert(conns, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    pcall(function() auraFolder.Parent = workspace.CurrentCamera end)
end))

local function evalSeq(seq, x, isColor)
    local ks = seq.Keypoints
    if x <= ks[1].Time then return ks[1].Value end
    for i = 2, #ks do
        local a, b = ks[i - 1], ks[i]
        if x <= b.Time then
            local span = b.Time - a.Time
            if span <= 0 then return b.Value end
            local t = (x - a.Time) / span
            if isColor then return a.Value:Lerp(b.Value, t) end
            return a.Value + (b.Value - a.Value) * t
        end
    end
    return ks[#ks].Value
end

local function auraShape(x)
    local f = math.clamp(x, 0, 1) * (#AURA_SHAPE - 1)
    local i = math.floor(f)
    local a, b = AURA_SHAPE[i + 1], AURA_SHAPE[math.min(i + 2, #AURA_SHAPE)]
    return (a + (b - a) * (f - i)) * AURA_WIDTH_FRACTION
end

local function auraWidth(a, x)
    local f = math.clamp(x, 0, 1) * AURA_CURVE_RES
    local i = math.floor(f)
    local lo, hi = a.curve[i + 1], a.curve[math.min(i + 2, AURA_CURVE_RES + 1)]
    return lo + (hi - lo) * (f - i)
end

local function removeAura(part)
    local a = auras[part]
    if not a then return end
    auras[part] = nil
    a.holder:Destroy()
    if a.trail.Parent then a.trail.WidthScale = a.width end
end

local function buildAura(part, trail)
    local pool = math.clamp(math.ceil(VIRTUAL_FPS * math.max(trail.Lifetime, 0.05) * 1.25) + 4, 32, 2000)
    local a = {
        trail = trail, width = trail.WidthScale, pool = pool, idx = 0, gap = true,
        atts = {}, beams = {}, times = {}, linked = {}, on = {}, level = {}, samples = {}, styleT = {}, styleC = {}, curve = {},
    }
    for i = 0, AURA_CURVE_RES do
        local x = i / AURA_CURVE_RES
        a.curve[i + 1] = evalSeq(a.width, x) * auraShape(x)
    end
    a.holder = Instance.new("Part")
    a.holder.Anchored, a.holder.CanCollide, a.holder.CanQuery, a.holder.CanTouch = true, false, false, false
    a.holder.Transparency = 1
    a.holder.CFrame = CFrame.new()
    a.holder.Parent = auraFolder
    for s = 1, pool do
        local att = Instance.new("Attachment")
        att.Parent = a.holder
        a.atts[s] = att
    end
    for s = 1, pool do
        local b = Instance.new("Beam")
        b.FaceCamera, b.Segments, b.Texture, b.Enabled = true, 1, "", false
        b.LightEmission, b.LightInfluence, b.Brightness = trail.LightEmission, trail.LightInfluence, trail.Brightness
        b.Attachment0, b.Attachment1 = a.atts[(s - 2) % pool + 1], a.atts[s]
        b.Parent = a.holder
        a.beams[s] = b
    end
    for i = 1, AURA_LEVELS do
        local x = (i - 0.5) / AURA_LEVELS
        a.styleT[i] = NumberSequence.new(evalSeq(trail.Transparency, x))
        a.styleC[i] = ColorSequence.new(evalSeq(trail.Color, x, true))
    end
    trail.WidthScale = NumberSequence.new(0)
    auras[part] = a
end

local function readyTrail(part)
    local trail = part:FindFirstChildOfClass("Trail")
    if trail and trail.Attachment0 and trail.Attachment1 and string.find(trail.Texture, AURA_TEXTURE, 1, true) then
        return trail
    end
    return nil
end

local function trackAura(part)
    if auras[part] or part.Name ~= "TrailPart" or not part:IsA("BasePart") then return end
    local trail = readyTrail(part)
    if trail then
        buildAura(part, trail)
        return
    end
    -- the part can be parented before its Trail, attachments or texture are filled in. Giving up
    -- right away left that trail on the original real-fps rendering for good, so keep checking a bit
    if pendingAura[part] then return end
    pendingAura[part] = true
    task.spawn(function()
        for _ = 1, 40 do
            task.wait(0.05)
            if not enabled or not part.Parent or auras[part] then break end
            local ready = readyTrail(part)
            if ready then
                buildAura(part, ready)
                break
            end
        end
        pendingAura[part] = nil
    end)
end

local function sampleAuras()
    for part, a in pairs(auras) do
        local p = part.Position
        if p ~= a.last and #a.samples < a.pool then
            a.last = p
            table.insert(a.samples, p)
        end
    end
end

local function paintAura(a, s, now, L, baseW)
    local prev = (s - 2) % a.pool + 1
    local aOld, aNew = math.min((now - a.times[prev]) / L, 1), math.max((now - a.times[s]) / L, 0)
    local b = a.beams[s]
    b.Width0 = baseW * auraWidth(a, aOld)
    b.Width1 = baseW * auraWidth(a, aNew)
    local lv = math.clamp(math.floor((aOld + aNew) * 0.5 * AURA_LEVELS) + 1, 1, AURA_LEVELS)
    if a.level[s] ~= lv then
        a.level[s] = lv
        b.Transparency = a.styleT[lv]
        b.Color = a.styleC[lv]
    end
end

local function setAuraBeam(a, s, visible)
    if a.on[s] ~= visible then
        a.beams[s].Enabled = visible
        a.on[s] = visible
    end
end

local function auraStyle(a)
    return math.max(a.trail.Lifetime, 0.05), (a.trail.Attachment0.WorldPosition - a.trail.Attachment1.WorldPosition).Magnitude
end

-- _WorldOrigin may not exist yet when this runs, or the game may recreate it later
local watching
local function watchOrigin(o)
    if watching == o then return end
    watching = o
    for _, c in ipairs(o:GetChildren()) do trackAura(c) end
    table.insert(conns, o.ChildAdded:Connect(trackAura))
    table.insert(conns, o.ChildRemoved:Connect(removeAura))
end
local origin = workspace:FindFirstChild("_WorldOrigin")
if origin then watchOrigin(origin) end
table.insert(conns, workspace.ChildAdded:Connect(function(c)
    if c.Name == "_WorldOrigin" then watchOrigin(c) end
end))

RunService:BindToRenderStep("FpsLarpAura", Enum.RenderPriority.Last.Value, function()
    local now = os.clock()
    sampleAuras()
    for part, a in pairs(auras) do
        if not part.Parent or not a.trail.Parent then
            removeAura(part)
        else
            local n = #a.samples
            if n > 0 then
                local L, baseW = auraStyle(a)
                local lastT, trailOn = a.lastT or now, a.trail.Enabled
                for i = 1, n do
                    if trailOn then
                        local prev = a.idx
                        a.idx = a.idx % a.pool + 1
                        local s = a.idx
                        a.times[s] = lastT + (now - lastT) * (i / n)
                        a.atts[s].Position = a.samples[i]
                        a.linked[s] = not a.gap and prev > 0
                        a.gap = false
                        if a.linked[s] then paintAura(a, s, now, L, baseW) end
                        setAuraBeam(a, s, a.linked[s])
                        setAuraBeam(a, s % a.pool + 1, false)
                    else
                        a.gap = true
                    end
                end
                table.clear(a.samples)
            end
            a.lastT = now
        end
    end
end)

local repaintAcc = 0
table.insert(conns, RunService.Heartbeat:Connect(function(dt)
    repaintAcc += dt
    if repaintAcc < 1 / 30 then return end
    repaintAcc = 0
    local now = os.clock()
    for _, a in pairs(auras) do
        if a.idx > 0 and a.trail.Parent then
            local L, baseW = auraStyle(a)
            local s = a.idx
            for _ = 1, a.pool do
                local ts = a.times[s]
                if not ts then break end
                local prev = (s - 2) % a.pool + 1
                local visible = a.linked[s] and (now - ts) / L < 1
                if visible then paintAura(a, s, now, L, baseW) end
                setAuraBeam(a, s, visible)
                if not visible and not a.on[prev] and (now - ts) / L >= 1 then break end
                s = prev
            end
        end
    end
end))

local signal = RunService.Heartbeat
local oldIndex
local indexHook = newcclosure(function(self, key)
    local value = oldIndex(self, key)
    if enabled and (WAIT_KEYS[key] or CONNECT_KEYS[key]) and not checkcaller() and FRAME_SIGNALS[tostring(self)] then
        if CONNECT_KEYS[key] then return wrapConnect(value) end
        local src = callerSource()
        if src and allowedSource(src) then
            if src == AURA_SOURCE then sampleAuras() end
            return wrapWait(value)
        end
    end
    return value
end)
local indexOk = pcall(function() oldIndex = hookmetamethod(signal, "__index", indexHook) end)
if not indexOk then warn("fps larp: could not hook frame signals") end

local function hookConnection(cn, prop)
    local fn = cn.Function
    if not (cn.LuaConnection and not cn.ForeignState and type(fn) == "function" and islclosure(fn) and not hooked[fn] and fnAllowed(fn)) then return end
    hooked[fn] = true
    local old
    local hookOk = pcall(function()
        old = hookfunction(fn, subStepped(function(...) return old(...) end, prop == "Stepped", function()
            local ok, on = pcall(connEnabled, cn)
            return ok and on
        end))
    end)
    if hookOk and old then
        table.insert(restores, function() hookfunction(fn, old) end)
    end
end

-- connections that already exist (or that slipped past the __index hook) can only be caught by hooking
-- their function in place, so this runs once now and then again in the background, one signal at a time
local function scanSignal(prop)
    local ok, list = pcall(function() return getconnections(RunService[prop]) end)
    if not ok or type(list) ~= "table" then return end
    for _, cn in ipairs(list) do
        pcall(hookConnection, cn, prop)
    end
end
for _, prop in ipairs(SIGNAL_LIST) do scanSignal(prop) end

local rescanAcc, rescanIdx = 0, 0
table.insert(conns, RunService.Heartbeat:Connect(function(dt)
    rescanAcc += dt
    if rescanAcc < RESCAN_SECONDS / #SIGNAL_LIST then return end
    rescanAcc = 0
    rescanIdx = rescanIdx % #SIGNAL_LIST + 1
    scanSignal(SIGNAL_LIST[rescanIdx])
end))

local oldNamecall
local namecallHook = newcclosure(function(self, ...)
    if enabled and self == RunService and not checkcaller() then
        local method = getnamecallmethod()
        if method == "BindToRenderStep" then
            local name, priority, fn = ...
            if type(name) == "string" and type(fn) == "function" and fnAllowed(fn) then
                local token = {}
                bindings[name] = token
                return oldNamecall(self, name, priority, portable(fn, false, function()
                    return bindings[name] == token
                end))
            end
        elseif method == "UnbindFromRenderStep" then
            local name = ...
            if type(name) == "string" then bindings[name] = nil end
        end
    end
    return oldNamecall(self, ...)
end)
local namecallOk = false
if HOOK_RENDER_STEP then
    namecallOk = pcall(function() oldNamecall = hookmetamethod(game, "__namecall", namecallHook) end)
    if not namecallOk then warn("fps larp: could not hook BindToRenderStep") end
end

local oldTaskWait
local taskWaitOk = pcall(function()
    oldTaskWait = hookfunction(task.wait, newcclosure(function(t, ...)
        if enabled and (t == nil or (type(t) == "number" and t <= 0)) and not checkcaller() and callerAllowed() then
            local st, boost = tryBoost()
            if boost then return STEP end
            return settle(st, oldTaskWait(t, ...))
        end
        return oldTaskWait(t, ...)
    end))
end)
if not taskWaitOk then warn("fps larp: could not hook task.wait") end

-- same count every frame, only moved when the frame rate drifts well away from it (a count that flips between
-- two values from frame to frame is what makes per-call motion lurch)
local function fixedSteps()
    local want = VIRTUAL_FPS * smoothDt
    if math.abs(want - fixedN) > 0.65 then
        fixedN = math.clamp(math.floor(want + 0.5), 1, MAX_STEPS)
    end
    return fixedN
end

-- fixed = every frame gets fixedSteps() calls and none are skipped for budget (and none are charged to it)
local function boostedLoop(duration, onStep, onEnd, done, fixed)
    local start, prev, carry, finished = time(), 0, 0, false
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        local elapsed = time() - start
        local steps
        if fixed then
            steps = fixedSteps()
        else
            carry += dt * VIRTUAL_FPS
            steps = math.clamp(math.floor(carry), 1, MAX_STEPS)
            carry = math.clamp(carry - steps, 0, MAX_STEPS)
        end
        local i, given = 1, 0
        while i <= steps do
            if not fixed and i < steps and spent >= frameBudget then i = steps end
            local e = prev + (elapsed - prev) * (i / steps)
            if e >= duration then break end
            local t0 = os.clock()
            local sub = if i == steps then dt - given else dt / steps
            given += sub
            onStep(e, sub, e / duration)
            if not conn.Connected then return end
            if not fixed and i < steps then spent += os.clock() - t0 end
            i += 1
        end
        prev = elapsed
        if elapsed >= duration and not finished then
            finished = true
            conn:Disconnect()
            if onEnd then onEnd() end
            if done then done() end
        end
    end)
    return conn
end

local util = ReplicatedStorage:FindFirstChild("Util")
local loopModule = util and util:FindFirstChild("HeartbeatLoopFor")
local loopLib = loopModule and require(loopModule)
local oldLoop, oldAwait
-- nil: leave the caller's loop alone, false: budgeted sub-stepping, true: steady sub-step count
local function loopMode()
    local src = callerSource()
    if src == nil then return nil end
    if FIXED_STEP[src] then return true end
    if allowedSource(src) then return false end
    return nil
end

if loopLib and type(loopLib.HeartbeatLoopFor) == "function" then
    oldLoop = hookfunction(loopLib.HeartbeatLoopFor, function(duration, onStep, onEnd)
        if enabled and type(onStep) == "function" and type(duration) == "number" then
            local fixed = loopMode()
            if fixed ~= nil then return boostedLoop(duration, onStep, onEnd, nil, fixed) end
        end
        return oldLoop(duration, onStep, onEnd)
    end)
end
if loopLib and type(loopLib.AwaitHeartbeatLoopFor) == "function" then
    oldAwait = hookfunction(loopLib.AwaitHeartbeatLoopFor, function(duration, onStep, onEnd)
        local fixed
        if enabled and type(onStep) == "function" and type(duration) == "number" then fixed = loopMode() end
        if fixed ~= nil then
            local ev = Instance.new("BindableEvent")
            boostedLoop(duration, onStep, onEnd, function() ev:Fire() end, fixed)
            ev.Event:Wait()
            ev:Destroy()
            return
        end
        return oldAwait(duration, onStep, onEnd)
    end)
end

getgenv().FpsLarp = function()
    enabled = false
    if genv.FpsLarpStep == step then genv.FpsLarpStep = nil end
    if indexOk and oldIndex then pcall(hookmetamethod, signal, "__index", oldIndex) end
    if namecallOk and oldNamecall then pcall(hookmetamethod, game, "__namecall", oldNamecall) end
    if taskWaitOk and oldTaskWait then pcall(hookfunction, task.wait, oldTaskWait) end
    if oldLoop then pcall(hookfunction, loopLib.HeartbeatLoopFor, oldLoop) end
    if oldAwait then pcall(hookfunction, loopLib.AwaitHeartbeatLoopFor, oldAwait) end
    for _, restore in ipairs(restores) do pcall(restore) end
    for _, c in ipairs(conns) do c:Disconnect() end
    pcall(function() RunService:UnbindFromRenderStep("FpsLarpAura") end)
    for part in pairs(auras) do removeAura(part) end
    auraFolder:Destroy()
    getgenv().FpsLarp = nil
end
