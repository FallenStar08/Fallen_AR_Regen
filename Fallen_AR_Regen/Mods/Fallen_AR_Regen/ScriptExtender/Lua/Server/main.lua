


local Context = {
    ShortRest = "REGEN_SHORT_REST_PERCENTAGE",
    CombatStarted = "REGEN_COMBAT_START_PERCENTAGE",
    CombatEnded = "REGEN_COMBAT_END_PERCENTAGE",
    LeveledUp = "REGEN_LEVELUP_PERCENTAGE",
}

--table of involved characters per combat guid
local CombatPartyMembers = {}
--table of decimal parts to regen later for each ressource
local RestoreActionResourcesDecimalPart = {}

-- -------------------------------------------------------------------------- --
--                               Core functions                               --
-- -------------------------------------------------------------------------- --
local function GetInvolvedPartyMembers(combatGuid)
    local partyMembers = {}
    local maxIndex = Osi.CombatGetInvolvedPartyMembersCount(combatGuid)

    for playerIndex = 0, maxIndex do
        local player = Osi.CombatGetInvolvedPlayer(combatGuid, playerIndex)
        if player ~= "" then
            table.insert(partyMembers, player)
        end
    end
    return partyMembers
end

local function UpdatePartyMembersForCombat(combatGuid)
    local partyMembers = GetInvolvedPartyMembers(combatGuid)
    CombatPartyMembers[combatGuid] = partyMembers
end

local function GetResources(entity)
    if entity then
        local resources = entity.ActionResources.Resources
        if resources then
            return resources
        else
            BasicError("RestoreActionResources() - Resources don't exist")
        end
    else
        return
    end
end

--- Get the percentage value based on the context.
---@param context string  The context enum (e.g., Context.ShortRest).
---@return number? percentage  The corresponding percentage (0-100).
local function GetPercentageForContextAndName(context, resource_name)
    if context then
        BasicDebug(string.format(
        "GetPercentageForContext() \n Getting percentage for resource : %s \n and context : %s", resource_name, context))
        if CONFIG.PER_RESOURCE_CONFIGURATION == 1 then
            local percentage = CONFIG.zREGEN[context][resource_name]
            if percentage then
                BasicDebug("GetPercentageForContext() - percentage : " .. percentage)
                return percentage
            end
        end
    else
        return 0
    end
    local percentage = CONFIG[context]
    BasicDebug("GetPercentageForContext() - percentage : " .. (percentage or 0))
    return tonumber(percentage) or 0
end

--- Restore action resources for a character based on the provided context.
---@param character string The UUID of the character.
---@param context string  The context enum (e.g., Context.ShortRest).
---@return nil
local function RestoreActionResources(character, context)
    local entity = Ext.Entity.Get(character)
    local resources = GetResources(entity)
    if not resources then return end
    for UUID, entity_data in pairs(resources) do
        for number, data in pairs(entity_data) do
            local maxAmount = data.MaxAmount
            local amount = data.Amount
            if amount==maxAmount then
                goto skip
            end
            local resourceName = Ext.StaticData.Get(UUID, "ActionResource").Name
            local percentage = GetPercentageForContextAndName(context, resourceName)
            local amountToRestore = maxAmount * (percentage / 100)

            -- Separate the integer and decimal parts
            local int_part = math.floor(amountToRestore)
            local decimal_part = amountToRestore - int_part
            -- Add the integer part to the current amount
            amount = amount + int_part
            -- Get the global decimal part for this ressource and accumulate it
            local globalDecimalPart = RestoreActionResourcesDecimalPart[UUID] or 0
            globalDecimalPart = globalDecimalPart + decimal_part

            -- Check if the global decimal part is >= 1, and if so, add it to the amount
            if globalDecimalPart >= 1 then
                local add_amount = math.floor(globalDecimalPart)
                amount = amount + add_amount
                globalDecimalPart = globalDecimalPart - add_amount
            end

            -- Ensure the amount does not exceed max_amount
            amount = math.min(amount, maxAmount)

            -- Update the global decimal part for this ressource
            RestoreActionResourcesDecimalPart[UUID] = globalDecimalPart

            data.Amount = amount

            entity:Replicate("ActionResources")
            local debugInfo = {
                resourceName = resourceName or "No Name",
                message = "RestoreActionResources()",
                percentage = percentage,
                UUID = UUID,
                character = GetTranslatedName(character)
            }
            BasicDebug(debugInfo)
            ::skip::
        end
    end
end



---@param context string  The context enum (e.g., Context.ShortRest).
local function RestoreActionResourcesForParty(context)
    local party = GetSquadies()
    for _, character in pairs(party) do
        RestoreActionResources(character, context)
    end
end

local function AddResourceEntries(config)
    local modified = false
    local resourceNames = {}
    for _, resource in pairs(Ext.StaticData.GetAll("ActionResource")) do
        table.insert(resourceNames, Ext.StaticData.Get(resource, "ActionResource").Name)
    end

    for _, context in pairs(Context) do
        config.zREGEN[context] = config.zREGEN[context] or {}
        for _, resourceName in pairs(resourceNames) do
            if config.zREGEN[context][resourceName] == nil then
                BasicDebug("Adding"..resourceName.." to the list")
                config.zREGEN[context][resourceName] = false
                modified = true
            end
        end
    end
    if modified then
        BasicPrint("AddResourceEntries() - Added new resources to the configuration file!")
        BasicDebug(CONFIG)
        CONFIG:save()
    else
        BasicDebug("AddResourceEntries() - No new resource(s)")
    end
end

-- -------------------------------------------------------------------------- --
--                                  listeners                                 --
-- -------------------------------------------------------------------------- --


-- Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(level, isEditorMode)

-- end)

Ext.Osiris.RegisterListener("ShortRested", 1, "after", function(character)
    RestoreActionResources(character, Context.ShortRest)
end)

Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
    RestoreActionResources(character, Context.LeveledUp)
end)


Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(combat)
    local combatGuid = combat
    local partyMembers = GetInvolvedPartyMembers(combatGuid)
    if #partyMembers >= 1 then
        RestoreActionResourcesForParty(Context.CombatStarted)
        -- Store party members in the global table with the combatGuid as the key
        CombatPartyMembers[combatGuid] = partyMembers
    else
        BasicDebug(string.format("EV_CombatStarted - No party members found for combat %s", combatGuid))
    end
end)

Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function(combat)
    local combatGuid = combat
    local partyMembers = CombatPartyMembers[combatGuid]
    if partyMembers and #partyMembers > 0 then
        -- At least one party member was still involved, restore action resources for all party members
        RestoreActionResourcesForParty(Context.CombatEnded)
    else
        BasicDebug(string.format("EV_CombatEnded - No party members found for combat %s", combatGuid))
    end
end)

Ext.Osiris.RegisterListener("EnteredCombat", 1, "after", function(character, combat)
    local combatGuid = combat
    if Osi.IsPlayer(character) == 1 then
        UpdatePartyMembersForCombat(combatGuid)
    end
end)

Ext.Osiris.RegisterListener("LeftCombat", 1, "after", function(character, combat)
    local combatGuid = combat
    if Osi.IsPlayer(character) == 1 then
        UpdatePartyMembersForCombat(combatGuid)
    end
end)


-- -------------------------------------------------------------------------- --
--                                   TEST                                     --
-- -------------------------------------------------------------------------- --
local function start()
    if not CONFIG then CONFIG=InitConfig() end
    if CONFIG.PER_RESOURCE_CONFIGURATION == 1 then
        AddResourceEntries(CONFIG)
    end
    Files.FlushLogBuffer()
end

Ext.Events.ResetCompleted:Subscribe(start)
Ext.Events.SessionLoaded:Subscribe(start)