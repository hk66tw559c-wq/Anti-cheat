-- ============================================================
-- MAXIMUM SECURITY ANTI-CHEAT v2.0
-- ServerScriptService → Script
-- ============================================================

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

-- ============================================================
-- CONFIG
-- ============================================================
local CFG = {
    WalkSpeed        = 16,    -- your game's real max walkspeed
    JumpPower        = 50,    -- your game's real max jumppower
    HipHeight        = 2.35,  -- default hip height
    MaxAirTime       = 5,     -- seconds before fly flag
    MaxRiseTime      = 1.8,   -- seconds rising before fly flag
    GroundRayLen     = 5,     -- studs downward to test "grounded"
    TeleportDist     = 55,    -- max legit stud-delta per tick
    SpeedTolerance   = 1.6,   -- multiplier over walkspeed allowed
    CheckRate        = 0.08,  -- seconds between checks (~12/sec)
    FlagLimit        = 6,     -- flags before kick
    BanOnLimit       = false, -- set true to use BanAsync
    Whitelist        = {},    -- { userId1, userId2 } devs
}

-- ============================================================
-- STATE
-- ============================================================
local pData = {}

local function newData()
    return {
        lastPos       = nil,
        airTime       = 0,
        riseTime      = 0,
        flags         = 0,
        cooldowns     = {},
        remotes       = {},
        lastValid     = nil,
    }
end

-- ============================================================
-- HELPERS
-- ============================================================
local function isWhitelisted(p)
    for _, id in ipairs(CFG.Whitelist) do
        if p.UserId == id then return true end
    end
    return false
end

local function cd(data, key, secs)
    local t = data.cooldowns[key] or 0
    if (tick() - t) < secs then return true end
    data.cooldowns[key] = tick()
    return false
end

local function safeGet(char, name)
    return char and char:FindFirstChild(name)
end

-- ============================================================
-- PUNISHMENT
-- ============================================================
local function punish(player, reason, data, lastSafe)
    if isWhitelisted(player) then return end
    data.flags += 1
    warn(("[AC] %s | %s | flags:%d"):format(player.Name, reason, data.flags))

    -- Always snap back first (silent correction)
    if lastSafe then
        local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(lastSafe + Vector3.new(0, 3, 0))
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end

    if data.flags >= CFG.FlagLimit then
        if CFG.BanOnLimit then
            pcall(function()
                Players:BanAsync({
                    UserIds         = { player.UserId },
                    ApplyToUniverse = true,
                    Duration        = -1,
                    DisplayReason   = "Cheating detected.",
                    PrivateReason   = "AntiCheat: " .. reason,
                    ExcludeAltAccounts = false,
                })
            end)
        end
        player:Kick("🚨 Anti-Cheat: " .. reason)
    end
end

-- ============================================================
-- GROUND CHECK  (raycast downward — more accurate than FloorMaterial)
-- ============================================================
local function isGrounded(root, char)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { char }
    local result = workspace:Raycast(root.Position, Vector3.new(0, -CFG.GroundRayLen, 0), params)
    return result ~= nil
end

-- ============================================================
-- NOCLIP CHECK  (dual-ray: center + offset to catch thin walls)
-- ============================================================
local function checkNoclip(player, char, root, oldPos, data)
    local newPos = root.Position
    local dir    = newPos - oldPos
    local dist   = dir.Magnitude
    if dist < 0.5 then return end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { char }

    local offsets = {
        Vector3.zero,
        Vector3.new(0, 1, 0),
        Vector3.new(0, -1, 0),
    }

    for _, offset in ipairs(offsets) do
        local origin = oldPos + offset
        local result = workspace:Raycast(origin, dir.Unit * dist, params)
        if result then
            local hit = result.Instance
            if hit and hit.CanCollide and not hit:IsDescendantOf(char) and hit.Transparency < 0.95 then
                if not cd(data, "noclip", 1.5) then
                    punish(player, "NoClip", data, oldPos)
                end
                return
            end
        end
    end
end

-- ============================================================
-- FLY CHECK
-- ============================================================
local function checkFly(player, char, root, hum, data, dt)
    local vel     = root.AssemblyLinearVelocity
    local grounded = isGrounded(root, char)

    if grounded then
        data.airTime  = 0
        data.riseTime = 0
        return
    end

    data.airTime += dt

    -- Rising upward beyond a legit jump arc
    if vel.Y > 2 then
        data.riseTime += dt
    else
        data.riseTime = math.max(0, data.riseTime - dt * 0.5)
    end

    -- Hovering / sustained flight
    if data.airTime > CFG.MaxAirTime then
        if not cd(data, "fly_air", 2) then
            punish(player, "Fly (hover)", data, data.lastValid)
            data.airTime = 0
        end
    end

    -- Sustained rising (BodyVelocity / fly scripts push Y constantly)
    if data.riseTime > CFG.MaxRiseTime then
        if not cd(data, "fly_rise", 2) then
            punish(player, "Fly (rise)", data, data.lastValid)
            data.riseTime = 0
        end
    end

    -- Abnormal humanoid state used by some fly scripts
    local state = hum:GetState()
    local badStates = {
        [Enum.HumanoidStateType.PlatformStanding] = true,
        [Enum.HumanoidStateType.StrafingNoPhysics] = true,
        [Enum.HumanoidStateType.FallingDown]       = false, -- legit
    }
    if badStates[state] == true and not grounded then
        if not cd(data, "fly_state", 3) then
            punish(player, "Fly (state: " .. tostring(state) .. ")", data, data.lastValid)
        end
    end
end

-- ============================================================
-- SPEED CHECK
-- ============================================================
local function checkSpeed(player, hum, root, data)
    local vel   = root.AssemblyLinearVelocity
    local hSpd  = Vector3.new(vel.X, 0, vel.Z).Magnitude
    local limit = math.max(hum.WalkSpeed, CFG.WalkSpeed) * CFG.SpeedTolerance

    if hSpd > limit then
        if not cd(data, "speed", 1) then
            punish(player, ("SpeedHack %.1f/%.1f"):format(hSpd, limit), data, data.lastValid)
            -- Hard-clamp velocity
            root.AssemblyLinearVelocity = Vector3.new(
                math.clamp(vel.X, -CFG.WalkSpeed, CFG.WalkSpeed),
                vel.Y,
                math.clamp(vel.Z, -CFG.WalkSpeed, CFG.WalkSpeed)
            )
        end
    end
end

-- ============================================================
-- TELEPORT CHECK
-- ============================================================
local function checkTeleport(player, root, data)
    local pos   = root.Position
    local last  = data.lastPos
    if not last then return end

    local delta = (pos - last).Magnitude
    if delta > CFG.TeleportDist then
        if not cd(data, "teleport", 2) then
            punish(player, ("Teleport %.1f studs"):format(delta), data, last)
            return true -- skip updating lastPos this tick
        end
    end
    return false
end

-- ============================================================
-- STAT CLAMP  (continuous — prevents WalkSpeed/JumpPower injection)
-- ============================================================
local function clampStats(hum)
    if hum.WalkSpeed > CFG.WalkSpeed * 1.5 then
        hum.WalkSpeed = CFG.WalkSpeed
    end
    if hum.JumpPower > CFG.JumpPower * 1.3 then
        hum.JumpPower = CFG.JumpPower
    end
    if hum.HipHeight > CFG.HipHeight * 2 then
        hum.HipHeight = CFG.HipHeight
    end
end

-- ============================================================
-- BODY MOVER WATCHER  (BodyVelocity / VectorForce = fly scripts)
-- ============================================================
local function watchBodyMovers(char, player, data)
    local function onAdded(obj)
        local bad = {
            "BodyVelocity", "BodyPosition", "BodyForce",
            "BodyGyro", "VectorForce", "LinearVelocity",
            "AlignPosition",
        }
        for _, name in ipairs(bad) do
            if obj:IsA(name) then
                obj:Destroy()
                if not cd(data, "mover_" .. name, 2) then
                    punish(player, "Injected " .. name, data, data.lastValid)
                end
            end
        end
    end

    char.DescendantAdded:Connect(onAdded)
end

-- ============================================================
-- REMOTE RATE LIMITER
-- ============================================================
local function hookRemotes()
    local calls = {}

    local function onFire(player, remoteName)
        local uid = player.UserId
        calls[uid] = calls[uid] or {}
        calls[uid][remoteName] = calls[uid][remoteName] or {}

        local now = tick()
        local list = calls[uid][remoteName]
        table.insert(list, now)

        -- Prune older than 1s
        local fresh = {}
        for _, t in ipairs(list) do
            if now - t <= 1 then table.insert(fresh, t) end
        end
        calls[uid][remoteName] = fresh

        if #fresh > 15 then
            local pd = pData[uid]
            if pd and not cd(pd, "remote_" .. remoteName, 3) then
                punish(player, "Remote spam: " .. remoteName, pd, pd.lastValid)
            end
        end
    end

    local function hookOne(obj)
        if obj:IsA("RemoteEvent") then
            obj.OnServerEvent:Connect(function(p, ...) onFire(p, obj.Name) end)
        end
    end

    for _, v in game.ReplicatedStorage:GetDescendants() do hookOne(v) end
    game.ReplicatedStorage.DescendantAdded:Connect(hookOne)

    Players.PlayerRemoving:Connect(function(p)
        calls[p.UserId] = nil
    end)
end

-- ============================================================
-- INVISIBILITY / GOD MODE CHECK
-- ============================================================
local function checkIntegrity(player, char, hum, data)
    -- Health above max = god mode script
    if hum.Health > hum.MaxHealth + 1 then
        if not cd(data, "godmode", 3) then
            hum.Health = hum.MaxHealth
            punish(player, "GodMode (Health > Max)", data, data.lastValid)
        end
    end

    -- MaxHealth tampered
    if hum.MaxHealth > 101 and hum.MaxHealth ~= math.huge then
        hum.MaxHealth = 100
        hum.Health = 100
    end
end

-- ============================================================
-- PER-PLAYER MAIN CHECK
-- ============================================================
local function monitor(player, dt)
    local data = pData[player.UserId]
    if not data then return end

    local char = player.Character
    if not char then return end

    local root = safeGet(char, "HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return end

    clampStats(hum)
    checkIntegrity(player, char, hum, data)
    checkSpeed(player, hum, root, data)

    local skipped = checkTeleport(player, root, data)
    if not skipped then
        if data.lastPos then
            checkNoclip(player, char, root, data.lastPos, data)
        end
        checkFly(player, char, root, hum, data, dt)
        data.lastValid = root.Position
        data.lastPos   = root.Position
    end
end

-- ============================================================
-- PLAYER LIFECYCLE
-- ============================================================
Players.PlayerAdded:Connect(function(player)
    pData[player.UserId] = newData()

    player.CharacterAdded:Connect(function(char)
        local data = pData[player.UserId]
        if data then
            data.lastPos   = nil
            data.lastValid = nil
            data.airTime   = 0
            data.riseTime  = 0
        end

        local hum = char:WaitForChild("Humanoid", 5)
        if hum then
            -- Lock stats on any change attempt
            hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
                if hum.WalkSpeed > CFG.WalkSpeed * 1.5 then
                    hum.WalkSpeed = CFG.WalkSpeed
                end
            end)
            hum:GetPropertyChangedSignal("JumpPower"):Connect(function()
                if hum.JumpPower > CFG.JumpPower * 1.3 then
                    hum.JumpPower = CFG.JumpPower
                end
            end)
        end

        watchBodyMovers(char, player, pData[player.UserId] or newData())
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    pData[player.UserId] = nil
end)

-- ============================================================
-- HEARTBEAT LOOP
-- ============================================================
local acc = 0
RunService.Heartbeat:Connect(function(dt)
    acc += dt
    if acc < CFG.CheckRate then return end
    local elapsed = acc
    acc = 0

    for _, player in Players:GetPlayers() do
        if pData[player.UserId] then
            pcall(monitor, player, elapsed)
        end
    end
end)

hookRemotes()
print("[AC] Maximum security loaded.")
