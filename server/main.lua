local playerScales = {}
local menuGrants = {}

local function debugPrint(message)
    if Config.Debug then
        print(('^3[crimson-pedscale]^0 %s'):format(message))
    end
end

-- ---------------------------------------------------------------------------
-- v45 inbound rate limiting.
--
-- Every client-callable event here used to be unauthenticated AND unbounded.
-- requestData and characterTransition additionally fan out a
-- TriggerClientEvent(-1) broadcast, so a single client could turn one event
-- into one packet per connected player -- a 1:N amplification primitive.
-- ---------------------------------------------------------------------------
local eventClock = {}   -- [src][eventName] = last accepted GetGameTimer()
local abuseState = {}   -- [src] = { strikes = n, blockedUntil = ms }

local function rateLimit(src, eventName)
    local limits = Config.Limits or {}
    if limits.Enabled == false then return true end

    local now = GetGameTimer()
    local abuse = abuseState[src]
    if abuse and abuse.blockedUntil and now < abuse.blockedUntil then
        return false
    end

    local cooldown = (limits.PerEventCooldownMs or {})[eventName]
        or tonumber(limits.DefaultCooldownMs) or 500

    eventClock[src] = eventClock[src] or {}
    local last = eventClock[src][eventName]
    if last and (now - last) < cooldown then
        abuse = abuse or { strikes = 0 }
        abuse.strikes = (abuse.strikes or 0) + 1
        if abuse.strikes >= (tonumber(limits.AbuseStrikes) or 8) then
            abuse.blockedUntil = now + (tonumber(limits.AbusePenaltyMs) or 10000)
            abuse.strikes = 0
            debugPrint(('rate-limit penalty applied to %s for %s'):format(src, eventName))
        end
        abuseState[src] = abuse
        return false
    end

    eventClock[src][eventName] = now
    if abuse then abuse.strikes = 0 end
    return true
end

local function notify(src, message, kind)
    if src and src > 0 then
        if GetResourceState('qbx_core') == 'started' then
            local qboxType = kind == 'error' and 'error' or kind == 'success' and 'success' or 'inform'
            local ok = pcall(function()
                exports.qbx_core:Notify(src, message, qboxType, 5000)
            end)
            if ok then return end
        end

        TriggerClientEvent('crimson-pedscale:client:notify', src, message, kind or 'primary')
    end
end

local function scaleDefaults()
    local default = tonumber(Config.Scale.Default) or 1.0
    local minScale = tonumber(Config.Scale.Min) or 0.87
    local maxScale = tonumber(Config.Scale.Max) or 1.10
    if minScale > maxScale then
        minScale, maxScale = maxScale, minScale
    end
    return default, minScale, maxScale
end

local function clampScale(scale)
    local default, minScale, maxScale = scaleDefaults()
    local value = tonumber(scale) or default
    if value < minScale then value = minScale end
    if value > maxScale then value = maxScale end
    return math.floor((value * 100.0) + 0.5) / 100.0
end

local function isDefaultScale(scale)
    local default = scaleDefaults()
    return math.abs((tonumber(scale) or default) - default) < 0.001
end

-- v45: findIdentifier/primaryIdentifier removed. Persistence keys on the
-- Qbox/QBCore citizenid (see characterIdentifier below), so the license
-- identifier lookup was unreachable. Config.Persistence.IdentifierPriority is
-- retained for config compatibility but is no longer consulted.

-- v30: Persist scale by CHARACTER, not by Rockstar/license account.
-- Qbox/QBCore citizenid is stable per character, so a .87 character can coexist
-- with a 1.10 character on the same account without either scale bleeding over.
local function characterIdentifier(src)
    if GetResourceState('qbx_core') == 'started' then
        local ok, player = pcall(function()
            return exports.qbx_core:GetPlayer(src)
        end)
        if ok and player and player.PlayerData and player.PlayerData.citizenid then
            return tostring(player.PlayerData.citizenid)
        end
    end

    if GetResourceState('qb-core') == 'started' then
        local ok, citizenid = pcall(function()
            local core = exports['qb-core']:GetCoreObject()
            local player = core.Functions.GetPlayer(src)
            return player and player.PlayerData and player.PlayerData.citizenid
        end)
        if ok and citizenid then return tostring(citizenid) end
    end

    -- Do NOT fall back to license persistence here. If character data is not
    -- ready yet, return nil so the client remains at 1.00 until it is ready.
    return nil
end

local function kvpKey(src)
    local citizenid = characterIdentifier(src)
    if not citizenid then return nil end
    return ('crp_pedscale:char:%s'):format(citizenid)
end

local function loadPlayerScale(src)
    if not Config.Persistence.Enabled then return scaleDefaults() end

    local key = kvpKey(src)
    if not key then return scaleDefaults() end

    local raw = GetResourceKvpString(key)
    if not raw then return scaleDefaults() end

    return clampScale(raw)
end

local function savePlayerScale(src, scale)
    if not Config.Persistence.Enabled then return end

    local key = kvpKey(src)
    if not key then return end

    if isDefaultScale(scale) then
        DeleteResourceKvp(key)
    else
        SetResourceKvp(key, tostring(clampScale(scale)))
    end
end

local function hasIdentifierPermission(src)
    for _, identifier in ipairs(GetPlayerIdentifiers(src)) do
        for _, allowed in ipairs(Config.Permission.Identifiers or {}) do
            if identifier == allowed then return true end
        end
    end
    return false
end

local function hasQBCorePermission(src)
    if GetResourceState('qb-core') ~= 'started' then return false end

    local ok, core = pcall(function()
        return exports['qb-core']:GetCoreObject()
    end)
    if not ok or not core or not core.Functions or not core.Functions.HasPermission then
        return false
    end

    for _, group in ipairs(Config.Permission.QBCoreGroups or {}) do
        local allowedOk, allowed = pcall(core.Functions.HasPermission, src, group)
        if allowedOk and allowed then return true end
    end

    return false
end

local function hasQBXPermission(src)
    if GetResourceState('qbx_core') ~= 'started' then return false end

    local ok, allowed = pcall(function()
        for _, group in ipairs(Config.Permission.QBCoreGroups or {}) do
            if exports.qbx_core:HasPermission(src, group) then
                return true
            end
        end
        return false
    end)

    return ok and allowed
end

local function hasESXPermission(src)
    if GetResourceState('es_extended') ~= 'started' then return false end

    local ok, group = pcall(function()
        local core = exports.es_extended:getSharedObject()
        local player = core.GetPlayerFromId(src)
        return player and player.getGroup()
    end)
    if not ok or not group then return false end

    for _, allowedGroup in ipairs(Config.Permission.ESXGroups or {}) do
        if group == allowedGroup then return true end
    end

    return false
end

local function hasPermission(src)
    if src == 0 then return true end
    if Config.Permission.UseAce and Config.Permission.Ace and IsPlayerAceAllowed(src, Config.Permission.Ace) then
        return true
    end
    return hasIdentifierPermission(src) or hasQBCorePermission(src) or hasQBXPermission(src) or hasESXPermission(src)
end

local function hasMenuGrant(src)
    local grant = menuGrants[src]
    if not grant then return false end

    if os.time() > grant.expires then
        menuGrants[src] = nil
        return false
    end

    return true
end

local function canUseMenu(src)
    return Config.Permission.AllowEveryoneSelfMenu or hasPermission(src) or hasMenuGrant(src)
end

local function publicScales()
    local data = {}
    for src, scale in pairs(playerScales) do
        if not isDefaultScale(scale) and GetPlayerName(src) then
            data[src] = scale
        end
    end
    return data
end

local function publishScale(src, scale)
    local normalized = clampScale(scale)
    if isDefaultScale(normalized) then
        playerScales[src] = nil
    else
        playerScales[src] = normalized
    end

    TriggerClientEvent('crimson-pedscale:client:updateScale', -1, src, normalized)
end

local function openMenu(target, opener)
    if not GetPlayerName(target) then return end

    local savedScale = playerScales[target] or loadPlayerScale(target)
    menuGrants[target] = {
        opener = opener,
        expires = os.time() + (tonumber(Config.MenuGrantSeconds) or 120)
    }

    TriggerClientEvent('crimson-pedscale:client:openMenu', target, {
        scale = savedScale,
        min = Config.Scale.Min,
        max = Config.Scale.Max,
        step = Config.Scale.Step,
        openedBy = opener and GetPlayerName(opener) or 'Server'
    })
end

RegisterNetEvent('crimson-pedscale:server:requestData', function()
    local src = source
    if not rateLimit(src, 'requestData') then return end
    local citizenid = characterIdentifier(src)

    -- Character swaps reuse the same server ID. Clear the previous character's
    -- live scale before loading anything for the newly selected character.
    if not citizenid then
        local default = scaleDefaults()
        publishScale(src, default)
        TriggerClientEvent('crimson-pedscale:client:fullSync', src, publicScales(), default)
        return
    end

    local savedScale = loadPlayerScale(src)
    publishScale(src, savedScale)
    TriggerClientEvent('crimson-pedscale:client:fullSync', src, publicScales(), savedScale)
end)

-- Client calls this immediately when its ped/character unloads or changes.
-- This prevents the old character's scale from remaining published under the
-- same server ID while the character selector/new ped is loading.
RegisterNetEvent('crimson-pedscale:server:characterTransition', function()
    local src = source
    if not rateLimit(src, 'characterTransition') then return end
    publishScale(src, scaleDefaults())
    menuGrants[src] = nil
end)

RegisterNetEvent('crimson-pedscale:server:saveScale', function(scale)
    local src = source
    if not rateLimit(src, 'saveScale') then return end
    if not canUseMenu(src) then
        debugPrint(('blocked save from %s'):format(src))
        return
    end

    local normalized = clampScale(scale)
    savePlayerScale(src, normalized)
    publishScale(src, normalized)
    menuGrants[src] = nil
    notify(src, ('Scale saved at %.2f.'):format(normalized), 'success')
end)

RegisterNetEvent('crimson-pedscale:server:resetScale', function()
    local src = source
    if not rateLimit(src, 'resetScale') then return end
    if not canUseMenu(src) then
        debugPrint(('blocked reset from %s'):format(src))
        return
    end

    local default = scaleDefaults()
    savePlayerScale(src, default)
    publishScale(src, default)
    menuGrants[src] = nil
    notify(src, 'Scale reset.', 'success')
end)

RegisterCommand(Config.Commands.OpenMenu, function(src)
    if src == 0 then
        print('This command must be used in game. Use /givepedscale [id] from console.')
        return
    end

    if not Config.Permission.AllowEveryoneSelfMenu and not hasPermission(src) then
        notify(src, 'You do not have permission to use this menu.', 'error')
        return
    end

    openMenu(src, src)
end, Config.Permission.RestrictCommandsWithAce == true)

RegisterCommand(Config.Commands.GiveMenu, function(src, args)
    if src ~= 0 and not hasPermission(src) then
        notify(src, 'You do not have permission to give the scale menu.', 'error')
        return
    end

    local target = tonumber(args[1])
    if not target or not GetPlayerName(target) then
        if src == 0 then
            print(('Usage: /%s [playerId]'):format(Config.Commands.GiveMenu))
        else
            notify(src, ('Usage: /%s [playerId]'):format(Config.Commands.GiveMenu), 'error')
        end
        return
    end

    openMenu(target, src > 0 and src or nil)
    if src > 0 then
        notify(src, ('Scale menu opened for ID %s.'):format(target), 'success')
    end
end, Config.Permission.RestrictCommandsWithAce == true)

RegisterCommand(Config.Commands.SetScale, function(src, args)
    if src ~= 0 and not hasPermission(src) then
        notify(src, 'You do not have permission to set scales.', 'error')
        return
    end

    local target
    local scale
    if args[2] then
        target = tonumber(args[1])
        scale = tonumber(args[2])
    else
        target = src
        scale = tonumber(args[1])
    end

    if not target or target == 0 or not GetPlayerName(target) or not scale then
        local usage = ('Usage: /%s [playerId] [scale]'):format(Config.Commands.SetScale)
        if src == 0 then print(usage) else notify(src, usage, 'error') end
        return
    end

    local normalized = clampScale(scale)
    savePlayerScale(target, normalized)
    publishScale(target, normalized)
    notify(target, ('Scale set to %.2f.'):format(normalized), 'success')
    if src > 0 and src ~= target then
        notify(src, ('ID %s scale set to %.2f.'):format(target, normalized), 'success')
    end
end, Config.Permission.RestrictCommandsWithAce == true)

RegisterCommand(Config.Commands.ResetScale, function(src, args)
    if src ~= 0 and not hasPermission(src) then
        notify(src, 'You do not have permission to reset scales.', 'error')
        return
    end

    local target = tonumber(args[1]) or src
    if not target or target == 0 or not GetPlayerName(target) then
        local usage = ('Usage: /%s [playerId]'):format(Config.Commands.ResetScale)
        if src == 0 then print(usage) else notify(src, usage, 'error') end
        return
    end

    local default = scaleDefaults()
    savePlayerScale(target, default)
    publishScale(target, default)
    notify(target, 'Scale reset.', 'success')
    if src > 0 and src ~= target then
        notify(src, ('ID %s scale reset.'):format(target), 'success')
    end
end, Config.Permission.RestrictCommandsWithAce == true)

-- v45: the hitbox guard has been REMOVED. The server no longer exposes
-- visualHeadHit / visualChestHit, and no longer relays damage to any client.
--
-- Those events accepted a fully attacker-supplied target id and relayed a
-- kill to the named victim with no proof a shot was ever fired. Measured on
-- v44: 200 crafted events produced 200 forced deaths, roughly 10 per second,
-- against any scaled player within 220m, through walls, by a player holding
-- no permissions at all.
--
-- It is removed rather than hardened because the design is contradictory: the
-- guard exists to compensate shots the engine scored as a MISS, so requiring
-- proof the shot landed refuses exactly the case it exists for while
-- double-damaging the hits that already landed. See the README.

AddEventHandler('playerDropped', function()
    local src = source
    playerScales[src] = nil
    menuGrants[src] = nil
    eventClock[src] = nil
    abuseState[src] = nil

    TriggerClientEvent('crimson-pedscale:client:removeScale', -1, src)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    ReportPedScaleConfig('server')

end)
