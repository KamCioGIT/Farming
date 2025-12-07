local RSGCore = exports['rsg-core']:GetCoreObject()
local PlayerData = {}
local Plants = {}
local RenderedPlants = {}

-- Ghost Placement Variables
local isPlacing = false
local ghostObject = nil
local currentPlantType = nil
local placementCoords = nil
local placementHeading = 0.0

-- Growth time in seconds (5 minutes)
local GROWTH_TIME = 300

--------------------------------------------------------------------------------
-- PLAYER LOAD/UNLOAD
--------------------------------------------------------------------------------
RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    PlayerData = RSGCore.Functions.GetPlayerData()
    TriggerServerEvent('rsg-farming:server:requestPlants')
end)

RegisterNetEvent('RSGCore:Client:OnPlayerUnload', function()
    PlayerData = {}
    for k, v in pairs(RenderedPlants) do
        if DoesEntityExist(v) then DeleteObject(v) end
    end
    RenderedPlants = {}
    Plants = {}
end)

--------------------------------------------------------------------------------
-- NUI FUNCTIONS
--------------------------------------------------------------------------------
local menuOpen = false

function ShowPlantMenu(plantId)
    local plant = Plants[plantId]
    if not plant then return end
    
    menuOpen = true
    SetNuiFocus(true, true)
    
    local waterPercent = plant.water or 0
    local healthPercent = plant.health or 100
    local weedPercent = plant.weed or 0
    local growthPercent = CalculateGrowth(plant)
    local timeRemaining = CalculateTimeRemaining(plant)
    
    SendNUIMessage({
        action = 'openPlantMenu',
        plantData = {
            id = plantId,
            type = plant.type,
            water = waterPercent,
            health = healthPercent,
            weed = weedPercent,
            fertilized = plant.fertilized,
            growth = growthPercent,
            timeRemaining = timeRemaining
        }
    })
end

function ShowProgress(title, duration)
    SendNUIMessage({
        action = 'showProgress',
        title = title,
        duration = duration
    })
end

function HideProgress()
    SendNUIMessage({ action = 'hideProgress' })
end

function ShowPopup(text, duration)
    SendNUIMessage({
        action = 'showPopup',
        text = text,
        duration = duration or 3000
    })
end

function HidePopup()
    SendNUIMessage({ action = 'hidePopup' })
end

-- Get current unix timestamp (client-safe)
function GetCurrentTime()
    -- Use network time or fallback to game timer approximation
    return GetNetworkTimeAccurate() / 1000
end

-- Calculate growth percentage based on server wateredTime
-- Calculate growth percentage based on server wateredTime
function CalculateGrowth(plant)
    if not plant.wateredTime then return 0 end
    
    local effectiveGrowthTime = GROWTH_TIME
    if plant.fertilized then
        effectiveGrowthTime = math.floor(GROWTH_TIME * 0.65) -- 35% faster
    end

    -- wateredTime is server os.time(), we use serverTimeOffset to sync
    local serverTime = plant.wateredTime
    local clientSyncTime = plant.clientSyncTime or plant.wateredTime
    
    -- Simpler: just use elapsed since wateredTime was set (synced via elapsedOnSync)
    local elapsed = 0
    if plant.elapsedOnSync then
        elapsed = plant.elapsedOnSync + ((GetGameTimer() - (plant.syncGameTimer or GetGameTimer())) / 1000)
    end
    
    local growthPercent = math.floor((elapsed / effectiveGrowthTime) * 100)
    return math.min(growthPercent, 100)
end

-- Calculate time remaining based on server wateredTime
function CalculateTimeRemaining(plant)
    local effectiveGrowthTime = GROWTH_TIME
    if plant.fertilized then
        effectiveGrowthTime = math.floor(GROWTH_TIME * 0.65) -- 35% faster
    end

    if not plant.wateredTime then return effectiveGrowthTime end
    
    if plant.elapsedOnSync then
        local elapsed = plant.elapsedOnSync + ((GetGameTimer() - (plant.syncGameTimer or GetGameTimer())) / 1000)
        local remaining = effectiveGrowthTime - elapsed
        return math.max(remaining, 0)
    end
    
    return effectiveGrowthTime
end

-- NUI Callbacks
RegisterNUICallback('plantAction', function(data, cb)
    cb('ok')
    menuOpen = false
    SetNuiFocus(false, false)
    
    local action = data.action
    local plantId = data.plantId
    
    if action == 'water' then
        WaterPlant(plantId)
    elseif action == 'harvest' then
        HarvestPlant(plantId)
    elseif action == 'destroy' then
        DestroyPlant(plantId)
    elseif action == 'removeWeeds' then
        RemoveWeeds(plantId)
    elseif action == 'fertilize' then
        FertilizePlant(plantId)
    end
end)

RegisterNUICallback('closeMenu', function(data, cb)
    cb('ok')
    menuOpen = false
    SetNuiFocus(false, false)
end)


--------------------------------------------------------------------------------
-- FARMING SHOP NPC (Third-Eye)
--------------------------------------------------------------------------------
CreateThread(function()
    if not Config.ShopNPCs then return end
    
    for i, shop in pairs(Config.ShopNPCs) do
        local shopIndex = i -- Fix for Lua closure capture
        local model = GetHashKey(shop.model)
        RequestModel(model)
        while not HasModelLoaded(model) do Wait(10) end
        
        local ped = CreatePed(model, shop.coords.x, shop.coords.y, shop.coords.z - 1.0, shop.heading, false, false, false, false)
        Citizen.InvokeNative(0x283978A15512B2FE, ped, true) -- SetRandomOutfitVariation
        SetEntityAsMissionEntity(ped, true, true)
        SetEntityInvincible(ped, true)
        FreezeEntityPosition(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        
        -- Blip
        if shop.blip and shop.blip.enabled then
            local blip = Citizen.InvokeNative(0x554D9D53F696D002, shop.coords.x, shop.coords.y, shop.coords.z)
            SetBlipSprite(blip, shop.blip.sprite, true)
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, shop.blip.label)
        end
        
        -- Interaction
        exports['rsg-target']:AddTargetEntity(ped, {
            options = {
                {
                    type = "client",
                    action = function()
                        TriggerServerEvent('rsg-farming:server:openShop', shopIndex)
                    end,
                    icon = "fas fa-seedling",
                    label = "Open Farming Shop",
                },
            },
            distance = 2.5,
        })
    end
end)


-- ESC Key Handler Thread (prevents getting stuck)
CreateThread(function()
    while true do
        Wait(0)
        if menuOpen then
            if IsControlJustPressed(0, 0x156F7119) then -- BACKSPACE/ESC
                SetNuiFocus(false, false)
                SendNUIMessage({ action = 'closeMenu' })
                menuOpen = false
            end
        else
            Wait(500)
        end
    end
end)


--------------------------------------------------------------------------------
-- GHOST OBJECT PLACEMENT SYSTEM
--------------------------------------------------------------------------------
local function GetGroundZ(x, y, z)
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 5.0, false)
    if found then
        return groundZ
    end
    return z
end

-- Forward declarations
local FinalizePlacement
local CancelPlacement

-- Cancel Placement Function
CancelPlacement = function()
    if DoesEntityExist(ghostObject) then
        DeleteObject(ghostObject)
        ghostObject = nil
    end
    isPlacing = false
    currentPlantType = nil
    placementCoords = nil
    HidePopup()
    exports.ox_lib:notify({ title = 'Cancelled', description = 'Planting cancelled', type = 'error' })
end

-- Finalize Placement Function
FinalizePlacement = function()
    if not isPlacing or not placementCoords then return end
    
    -- Delete ghost
    if DoesEntityExist(ghostObject) then
        DeleteObject(ghostObject)
        ghostObject = nil
    end
    
    HidePopup()
    ShowPopup('Planting ' .. currentPlantType .. '...', 5000)
    
    -- Play planting animation
    TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_FARMER_RAKE'), -1, true, false, false, false)
    ShowProgress('Planting Seeds...', 5000)
    
    Wait(5000)
    ClearPedTasks(PlayerPedId())
    HideProgress()
    HidePopup()
    
    local plantData = {
        type = currentPlantType,
        coords = { x = placementCoords.x, y = placementCoords.y, z = placementCoords.z },
        heading = placementHeading,
        -- Default stats set by server, but client can init basic ones
        water = 0,
        growth = 0,
        stage = 1,
        plantedTime = GetGameTimer()
    }
    TriggerServerEvent('rsg-farming:server:plantSeed', plantData)
    
    isPlacing = false
    currentPlantType = nil
    placementCoords = nil
    
    ShowPopup('Seeds Planted!', 2000)
end

local function StartPlacement(plantType)
    if isPlacing then return end
    
    if Config.EnableBannedZones and Config.BannedZones then
        local pCoords = GetEntityCoords(PlayerPedId())
        for _, zone in pairs(Config.BannedZones) do
            if #(pCoords - zone.coords) < zone.radius then
                exports.ox_lib:notify({ title = 'Restricted Area', description = 'Farming is not allowed in ' .. zone.name, type = 'error' })
                return
            end
        end
    end
    
    local seedData = Config.Seeds[plantType]
    if not seedData then
        exports.ox_lib:notify({ title = 'Error', description = 'Invalid seed type', type = 'error' })
        return
    end
    
    isPlacing = true
    currentPlantType = plantType
    placementHeading = 0.0
    
    local propName = seedData.prop
    local model = GetHashKey(propName)
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(10) end
    
    local playerCoords = GetEntityCoords(PlayerPedId())
    local groundZ = GetGroundZ(playerCoords.x, playerCoords.y, playerCoords.z)
    
    ghostObject = CreateObject(model, playerCoords.x, playerCoords.y + 2.0, groundZ - (seedData.offset or 0.0), false, false, false)
    SetEntityAlpha(ghostObject, 150, false)
    SetEntityCollision(ghostObject, false, false)
    FreezeEntityPosition(ghostObject, true)
    
    ShowPopup('PLACE ' .. string.upper(plantType) .. ' • ENTER to Plant • BACKSPACE to Cancel', 0)

    
    CreateThread(function()
        while isPlacing do
            Wait(0)
            
            local playerCoords = GetEntityCoords(PlayerPedId())
            local camRot = GetGameplayCamRot(2)
            local forward = vector3(
                -math.sin(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)),
                math.cos(math.rad(camRot.z)) * math.cos(math.rad(camRot.x)),
                0.0
            )
            local right = vector3(
                math.cos(math.rad(camRot.z)),
                math.sin(math.rad(camRot.z)),
                0.0
            )
            
            -- Get ghost position (in front of player)
            local offset = 2.5
            local ghostPos = playerCoords + (forward * offset)
            
            -- Movement controls
            if IsControlPressed(0, 0x7065027D) then -- W
                ghostPos = ghostPos + (forward * 0.05)
            end
            if IsControlPressed(0, 0xD27782E3) then -- S
                ghostPos = ghostPos - (forward * 0.05)
            end
            if IsControlPressed(0, 0x05CA7C52) then -- A
                ghostPos = ghostPos - (right * 0.05)
            end
            if IsControlPressed(0, 0x6319DB71) then -- D
                ghostPos = ghostPos + (right * 0.05)
            end
            
            -- Rotation controls
            if IsControlPressed(0, 0xDE794E3E) then -- Q
                placementHeading = placementHeading + 1.0
            end
            if IsControlPressed(0, 0xCEFD9220) then -- E
                placementHeading = placementHeading - 1.0
            end
            
            -- Get ground Z for ghost position
            local groundZ = GetGroundZ(ghostPos.x, ghostPos.y, ghostPos.z)
            placementCoords = vector3(ghostPos.x, ghostPos.y, groundZ)
            
            -- Update ghost object position
            if DoesEntityExist(ghostObject) then
                SetEntityCoords(ghostObject, placementCoords.x, placementCoords.y, placementCoords.z - (seedData.offset or 0.0), false, false, false, false)
                SetEntityHeading(ghostObject, placementHeading)
            end
            
            -- Confirm placement
            if IsControlJustPressed(0, 0xC7B5340A) then -- ENTER
                FinalizePlacement()
            end
            
            -- Cancel placement
            if IsControlJustPressed(0, 0x156F7119) then -- BACKSPACE
                CancelPlacement()
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- PLANT SYNC EVENTS
--------------------------------------------------------------------------------
RegisterNetEvent('rsg-farming:client:syncPlants', function(serverPlants)
    Plants = serverPlants or {}
    local syncTime = GetGameTimer()
    for id, plant in pairs(Plants) do
        plant.syncGameTimer = syncTime
        SpawnPlantProp(id, plant)
    end
end)

RegisterNetEvent('rsg-farming:client:addPlant', function(plantData)
    plantData.syncGameTimer = GetGameTimer()
    plantData.elapsedOnSync = 0 -- Just planted, no elapsed time
    Plants[plantData.id] = plantData
    SpawnPlantProp(plantData.id, plantData)
end)

RegisterNetEvent('rsg-farming:client:updatePlant', function(plantId, newData)
    newData.syncGameTimer = GetGameTimer()
    -- If just watered, set elapsed to 0
    if newData.wateredTime and (not Plants[plantId] or not Plants[plantId].wateredTime) then
        newData.elapsedOnSync = 0
    elseif newData.wateredTime then
        -- Keep existing elapsed or recalculate
        newData.elapsedOnSync = Plants[plantId].elapsedOnSync or 0
    end
    Plants[plantId] = newData
end)

RegisterNetEvent('rsg-farming:client:removePlant', function(plantId)
    if RenderedPlants[plantId] then
        exports['rsg-target']:RemoveTargetEntity(RenderedPlants[plantId])
        DeleteObject(RenderedPlants[plantId])
        RenderedPlants[plantId] = nil
    end
    Plants[plantId] = nil
end)

--------------------------------------------------------------------------------
-- SPAWN PLANT PROP WITH THIRD-EYE
--------------------------------------------------------------------------------
function SpawnPlantProp(id, plant)
    if RenderedPlants[id] then return end
    
    local seedData = Config.Seeds[plant.type]
    if not seedData then return end
    
    local propName = seedData.prop
    local model = GetHashKey(propName)
    RequestModel(model)
    local timeout = 0
    while not HasModelLoaded(model) and timeout < 100 do
        Wait(10)
        timeout = timeout + 1
    end
    
    if not HasModelLoaded(model) then return end
    
    local coords = vector3(plant.coords.x, plant.coords.y, plant.coords.z)
    local groundZ = GetGroundZ(coords.x, coords.y, coords.z)
    
    local obj = CreateObject(model, coords.x, coords.y, groundZ - (seedData.offset or 0.0), false, false, false)
    SetEntityAsMissionEntity(obj, true, true)
    FreezeEntityPosition(obj, true)
    SetEntityHeading(obj, plant.heading or 0.0)
    SetEntityCollision(obj, true, true)
    
    RenderedPlants[id] = obj
    
    -- Add Third-Eye Target to Plant
    exports['rsg-target']:AddTargetEntity(obj, {
        options = {
            {
                type = "client",
                action = function()
                    ShowPlantMenu(id)
                end,
                icon = "fas fa-seedling",
                label = "Inspect Crop",
            },
        },
        distance = 3.0,
    })
end

--------------------------------------------------------------------------------
-- PLANT INTERACTION FUNCTIONS
--------------------------------------------------------------------------------
function WaterPlant(plantId)
    local plant = Plants[plantId]
    if not plant then return end
    
    -- Check if player has water/bucket
    local hasWater = exports['rsg-inventory']:HasItem('fullbucket', 1)
    if not hasWater then
        exports.ox_lib:notify({ title = 'Error', description = 'You need a full bucket of water', type = 'error' })
        return
    end
    
    ShowPopup('Watering Crop...', 4000)
    TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_BUCKET_POUR_LOW'), -1, true, false, false, false)
    ShowProgress('Watering...', 4000)
    
    Wait(4000)
    ClearPedTasks(PlayerPedId())
    HideProgress()
    HidePopup()
    
    TriggerServerEvent('rsg-farming:server:waterPlant', plantId)
    ShowPopup('Crop Watered!', 2000)
end

function RemoveWeeds(plantId)
    local plant = Plants[plantId]
    if not plant then return end
    
    ShowPopup('Removing Weeds...', 5000)
    TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_FARMER_WEEDING'), -1, true, false, false, false)
    ShowProgress('Removing Weeds...', 5000)
    
    Wait(5000)
    ClearPedTasks(PlayerPedId())
    HideProgress()
    HidePopup()
    
    TriggerServerEvent('rsg-farming:server:removeWeeds', plantId)
    ShowPopup('Weeds Removed!', 2000)
end

function FertilizePlant(plantId)
    local plant = Plants[plantId]
    if not plant then return end
    
    local hasItem = exports['rsg-inventory']:HasItem('fertilizer', 1)
    if not hasItem then
        exports.ox_lib:notify({ title = 'Error', description = 'You need fertilizer', type = 'error' })
        return
    end

    ShowPopup('Fertilizing...', 4000)
    TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_FARMER_RAKE'), -1, true, false, false, false)
    ShowProgress('Fertilizing...', 4000)
    
    Wait(4000)
    ClearPedTasks(PlayerPedId())
    HideProgress()
    HidePopup()
    
    TriggerServerEvent('rsg-farming:server:fertilizePlant', plantId)
end

function HarvestPlant(plantId)
    local plant = Plants[plantId]
    if not plant then return end
    
    -- Check if fully grown
    local growthPercent = CalculateGrowth(plant)
    if growthPercent < 100 then
        exports.ox_lib:notify({ title = 'Error', description = 'Crop is not ready to harvest yet', type = 'error' })
        return
    end
    
    ShowPopup('Harvesting Crop...', 5000)
    TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_FARMER_RAKE'), -1, true, false, false, false)
    ShowProgress('Harvesting...', 5000)
    
    Wait(5000)
    ClearPedTasks(PlayerPedId())
    HideProgress()
    HidePopup()
    
    TriggerServerEvent('rsg-farming:server:harvest', plantId)
    ShowPopup('Crop Harvested!', 2000)
end

function DestroyPlant(plantId)
    ShowPopup('Destroying Crop...', 3000)
    TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_FARMER_RAKE'), -1, true, false, false, false)
    ShowProgress('Destroying...', 3000)
    
    Wait(3000)
    ClearPedTasks(PlayerPedId())
    HideProgress()
    HidePopup()
    
    TriggerServerEvent('rsg-farming:server:destroyPlant', plantId)
    ShowPopup('Crop Destroyed', 2000)
end

--------------------------------------------------------------------------------
-- USE SEED EVENT (Triggers Ghost Placement)
--------------------------------------------------------------------------------
RegisterNetEvent('rsg-farming:client:useSeed', function(plantType)
    StartPlacement(plantType)
end)

--------------------------------------------------------------------------------
-- WATER INTERACTION (Rivers/Pumps)
--------------------------------------------------------------------------------
local function ShowWaterMenu()
    if menuOpen then return end
    menuOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openWaterMenu' })
end

RegisterNUICallback('closeWaterMenu', function(data, cb)
    cb('ok')
    menuOpen = false
    SetNuiFocus(false, false)
end)

RegisterNUICallback('waterAction', function(data, cb)
    cb('ok')
    menuOpen = false
    SetNuiFocus(false, false)
    
    local action = data.action
    
    if action == 'fillBucket' then
        TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_BUCKET_POUR_LOW'), -1, true, false, false, false)
        ShowProgress('Filling Bucket...', 4000)
        Wait(4000)
        ClearPedTasks(PlayerPedId())
        HideProgress()
        TriggerServerEvent('rsg-farming:server:fillBucket')
        
    elseif action == 'drink' then
        TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_BUCKET_DRINK_GROUND'), -1, true, false, false, false)
        ShowProgress('Drinking...', 5000)
        Wait(5000)
        ClearPedTasks(PlayerPedId())
        HideProgress()
        TriggerServerEvent("RSGCore:Server:SetMetaData", "thirst", RSGCore.Functions.GetPlayerData().metadata["thirst"] + 50)
        
    elseif action == 'wash' then
        TaskStartScenarioInPlace(PlayerPedId(), GetHashKey('WORLD_HUMAN_BUCKET_DRINK_GROUND'), -1, true, false, false, false)
        ShowProgress('Washing...', 5000)
        Wait(5000)
        ClearPedTasks(PlayerPedId())
        HideProgress()
        ClearPedEnvDirt(PlayerPedId())
        ClearPedBloodDamage(PlayerPedId())
    end
end)

-- Helper text
local function DrawText3Ds(x, y, z, text)
    local onScreen, _x, _y = GetScreenCoordFromWorldCoord(x, y, z)
    SetTextScale(0.35, 0.35)
    SetTextFontForCurrentCommand(1)
    SetTextColor(255, 255, 255, 215)
    local str = CreateVarString(10, "LITERAL_STRING", text, Citizen.ResultAsLong())
    SetTextCentre(1)
    DisplayText(str, _x, _y)
end

-- Water/Pump Thread
CreateThread(function()
    while true do
        Wait(1)
        local sleep = true
        local coords = GetEntityCoords(PlayerPedId())
        local Water = Citizen.InvokeNative(0x5BA7A68A346A5A91, coords.x+3, coords.y+3, coords.z)
        
        local inWater = false
        if Config.WaterTypes then
            for _, v in pairs(Config.WaterTypes) do
                if Water == v.waterhash then
                    inWater = true
                    break
                end
            end
        end

        -- Water Interaction
        if inWater and IsPedOnFoot(PlayerPedId()) and IsEntityInWater(PlayerPedId()) then
            sleep = false
            DrawText3Ds(coords.x, coords.y, coords.z + 1.0, "[G] Water Source")
            
            if IsControlJustReleased(0, 0x760A9C6F) then -- G key (standard) or check Config
                ShowWaterMenu()
            end
        end

        -- Pump Logic
        local pumpObject = GetClosestObjectOfType(coords, 3.0, GetHashKey("p_waterpump01x"), false, false, false)
        if pumpObject ~= 0 then
            sleep = false
            local pumpCoords = GetEntityCoords(pumpObject)
            DrawText3Ds(pumpCoords.x, pumpCoords.y, pumpCoords.z + 1.0, "[G] Water Pump")
            if IsControlJustReleased(0, 0x760A9C6F) then -- G key
                ShowWaterMenu()
            end
        end
        
        if sleep then Wait(1000) end
    end
end)
