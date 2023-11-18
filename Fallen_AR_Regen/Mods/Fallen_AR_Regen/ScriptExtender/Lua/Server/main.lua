Ext.Require("Server/_ModInfos.lua")
Ext.Require("Shared/_Globals.lua")
Ext.Require("Shared/_Utils.lua")
Ext.Require("Server/_Config.lua")


-- -------------------------------------------------------------------------- --
--                                   GLOBALS                                  --
-- -------------------------------------------------------------------------- --

Context = {
    ShortRest = "REGEN_SHORT_REST_PERCENTAGE",
    CombatStarted = "REGEN_COMBAT_START_PERCENTAGE",
    CombatEnded = "REGEN_COMBAT_END_PERCENTAGE",
    LeveledUp = "REGEN_LEVELUP_PERCENTAGE",
}
-- Global table of involved characters per combat guid
_G.CombatPartyMembers = _G.CombatPartyMembers or {}
-- Global table of decimal parts to regen later for each ressource
_G.RestoreActionResourcesDecimalPart = _G.RestoreActionResourcesDecimalPart or {}
-- -------------------------------------------------------------------------- --
--                                General Stuff                               --
-- -------------------------------------------------------------------------- --


function MergeSquadiesAndSummonies()
    local mergedList = {}
    local squadies = GetSquadies()
    local summonies = GetSummonies()
    for _, squady in pairs(squadies) do
        table.insert(mergedList, squady)
    end
    for _, summon in pairs(summonies) do
        table.insert(mergedList, summon)
    end
    BasicDebug(mergedList)
    return mergedList
end

-- -------------------------------------------------------------------------- --
--                               Core functions                               --
-- -------------------------------------------------------------------------- --
function GetInvolvedPartyMembers(combatGuid)
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

function UpdatePartyMembersForCombat(combatGuid)
    local partyMembers = GetInvolvedPartyMembers(combatGuid)
    _G.CombatPartyMembers[combatGuid] = partyMembers
end

function GetResources(entity)
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

--- Restore action resources for a character based on the provided context.
---@param character string The UUID of the character.
---@param context string  The context enum (e.g., Context.ShortRest).
---@return nil
function RestoreActionResources(character, context)
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
            local globalDecimalPart = _G.RestoreActionResourcesDecimalPart[UUID] or 0
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
            _G.RestoreActionResourcesDecimalPart[UUID] = globalDecimalPart

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

--- Get the percentage value based on the context.
---@param context string  The context enum (e.g., Context.ShortRest).
---@return number percentage  The corresponding percentage (0-100).
function GetPercentageForContextAndName(context, resource_name)
    if context then
        BasicDebug(string.format(
        "GetPercentageForContext() \n Getting percentage for resource : %s \n and context : %s", resource_name, context))
        if Config.GetValue(Config.config_tbl, "PER_RESOURCE_CONFIGURATION") == 1 then
            local percentage = Config.config_tbl.zREGEN[context][resource_name]
            if percentage then
                BasicDebug("GetPercentageForContext() - percentage : " .. percentage)
                return percentage
            end
        end
    else
        return 0
    end
    local percentage = Config.GetValue(Config.config_tbl, context)
    BasicDebug("GetPercentageForContext() - percentage : " .. (percentage or 0))
    return percentage
end

---@param context string  The context enum (e.g., Context.ShortRest).
function RestoreActionResourcesForParty(context)
    local party = GetSquadies()
    for _, character in pairs(party) do
        RestoreActionResources(character, context)
    end
end

function AddResourceEntries(config)
    local modified = false
    local resourceNames = {}
    for _, resource in pairs(Ext.StaticData.GetAll("ActionResource")) do
        table.insert(resourceNames, Ext.StaticData.Get(resource, "ActionResource").Name)
    end

    for _, context in pairs(Context) do
        config.zREGEN[context] = config.zREGEN[context] or {}
        for _, resourceName in pairs(resourceNames) do
            if config.zREGEN[context][resourceName] == nil then
                config.zREGEN[context][resourceName] = false
                modified = true
            end
        end
    end
    if modified then
        BasicDebug("AddResourceEntries() - Added new resources to the configuration file!")
        Config.SaveConfig(Config.config_json_file_path, config)
    else
        BasicDebug("AddResourceEntries() - No new resource(s)")
    end
end

-- -------------------------------------------------------------------------- --
--                                  listeners                                 --
-- -------------------------------------------------------------------------- --
Ext.Events.SessionLoaded:Subscribe(function()
    if not Config.initDone then Config.Init() end
    if Config.GetValue(Config.config_tbl, "PER_RESOURCE_CONFIGURATION") == 1 then
        AddResourceEntries(Config.config_tbl)
    end
    Files.FlushLogBuffer()
end)

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
        _G.CombatPartyMembers[combatGuid] = partyMembers
    else
        BasicDebug(string.format("EV_CombatStarted - No party members found for combat %s", combatGuid))
    end
end)

Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function(combat)
    local combatGuid = combat
    local partyMembers = _G.CombatPartyMembers[combatGuid]
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
Ext.Events.ResetCompleted:Subscribe(function()

    if not Config.initDone then Config.Init() end
    if Config.GetValue(Config.config_tbl, "PER_RESOURCE_CONFIGURATION") == 1 then
        AddResourceEntries(Config.config_tbl)
    end
    Files.FlushLogBuffer()
end)
