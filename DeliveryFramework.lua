local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PackagePool = require(ReplicatedStorage.Modules.Shared.Objects.PackagePool)
local DataManager = require(ReplicatedStorage.Modules.Data.DataManager)

-- Creates random package data when a player picks up a delivery
local packagePool = PackagePool.new()

-- Folder that holds all package tool templates
local packageTemplateFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("PackageTemplates")

-- Tracks prompt debounce per player so they cannot spam pickup prompts
local playerPromptDebounce = {}

-- Tracks active timer loops so each player only gets one running loop
local activeTimerLoops = {}

-- Small delay between pickup prompt uses
local PICKUP_DEBOUNCE_TIME = 1.5

-- Max deliveries a player can hold at once
local MAX_DELIVERIES = 3

-- Tags used to find valid house delivery points
local HOUSE_TAGS = {
	"HouseRegular",
	"HouseAdvanced",
}

local function getHouseModelFromTaggedInstance(instance)
	if not instance then
		return nil
	end

	local current = instance

	-- Walks until a model is found
	while current and current.Parent do
		if current:IsA("Model") then
			return current
		end
		current = current.Parent
	end

	return nil
end

local function getDeliveryPartFromTaggedInstance(instance)
	-- Finds the house model that owns this tagged attachment
	local houseModel = getHouseModelFromTaggedInstance(instance)
	if not houseModel then
		return nil
	end

	-- Looks for the delivery part anywhere inside the model
	local deliveryPart = houseModel:FindFirstChild("DeliveryPart", true)
	if deliveryPart and deliveryPart:IsA("BasePart") then
		return deliveryPart
	end

	return nil
end

local function getAllDeliveryDestinations()
	local destinations = {}

	-- Loops through every supported house tag
	for _, tag in ipairs(HOUSE_TAGS) do
		-- Gets all tagged objects for that house type
		for _, instance in ipairs(CollectionService:GetTagged(tag)) do
			if instance:IsA("Attachment") then
				local index = instance:GetAttribute("Index")
				local houseModel = getHouseModelFromTaggedInstance(instance)
				local deliveryPart = getDeliveryPartFromTaggedInstance(instance)

				-- Only stores destinations that are fully valid
				if type(index) == "number" and houseModel and deliveryPart then
					table.insert(destinations, {
						TaggedAttachment = instance,
						HouseModel = houseModel,
						Part = deliveryPart,
						Tag = tag,
						Index = index,
					})
				else
					warn(
						"Invalid delivery destination:",
						instance:GetFullName(),
						"Tag =", tag,
						"Index =", index,
						"HouseModel =", houseModel and houseModel:GetFullName() or "nil",
						"DeliveryPart =", deliveryPart and deliveryPart:GetFullName() or "nil"
					)
				end
			end
		end
	end

	return destinations
end

local function getRandomDeliveryDestination()
	local allDestinations = getAllDeliveryDestinations()

	-- Stops early if no houses are available
	if #allDestinations == 0 then
		return nil
	end

	-- Picks one destination at random
	local chosen = allDestinations[Random.new():NextInteger(1, #allDestinations)]

	return {
		TaggedAttachment = chosen.TaggedAttachment,
		HouseModel = chosen.HouseModel,
		Part = chosen.Part,
		Tag = chosen.Tag,
		Index = chosen.Index,
		DisplayName = string.format("%s %d", chosen.Tag, chosen.Index),
	}
end

local function getDeliveryCount(deliveries)
	local count = 0

	-- Counts how many active deliveries the player has
	for _ in pairs(deliveries or {}) do
		count += 1
	end

	return count
end

local function makeDeliveryData(package)
	local summary = package:GetSummary()
	local destination = getRandomDeliveryDestination()

	if not destination then
		warn("No delivery destinations found")
		return nil
	end

	-- Builds the delivery data that gets saved for the player
	return {
		Id = summary.Id,
		Type = summary.Type,
		Reward = summary.Reward,
		Time = summary.Time,
		RemainingTime = summary.Time,
		Location = destination.DisplayName,
		DestinationTag = destination.Tag,
		DestinationIndex = destination.Index,
		Delivered = summary.Delivered,
	}
end

local function getToolNameFromDelivery(deliveryData)
	if type(deliveryData) ~= "table" then
		return nil
	end

	-- Uses the package type as the tool name
	-- This means your tool template names must match the package type names
	return deliveryData.Type
end

local function getBackpack(player)
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		return backpack
	end

	-- Waits briefly in case the backpack has not loaded yet
	return player:WaitForChild("Backpack", 5)
end

local function toolAlreadyExists(player, deliveryId)
	local function hasTool(container)
		if not container then
			return false
		end

		-- Checks backpack or character for a tool tied to this delivery
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute("DeliveryId") == deliveryId then
				return true
			end
		end

		return false
	end

	return hasTool(player:FindFirstChild("Backpack")) or hasTool(player.Character)
end

local function giveToolForDelivery(player, deliveryId, deliveryData)
	if not player or not player.Parent then
		return
	end

	if type(deliveryData) ~= "table" then
		return
	end

	-- Prevents duplicate tools for the same delivery
	if toolAlreadyExists(player, deliveryId) then
		return
	end

	local toolName = getToolNameFromDelivery(deliveryData)
	if not toolName then
		warn("No tool name found for delivery type:", deliveryData.Type)
		return
	end

	-- Gets the correct template tool from storage
	local templateTool = packageTemplateFolder:FindFirstChild(toolName)
	if not templateTool or not templateTool:IsA("Tool") then
		warn("Missing package tool template for:", toolName)
		return
	end

	local backpack = getBackpack(player)
	if not backpack then
		warn("Backpack not found for:", player.Name)
		return
	end

	-- Creates a fresh tool and tags it with delivery data
	local toolClone = templateTool:Clone()
	toolClone.Name = toolName
	toolClone:SetAttribute("DeliveryId", deliveryId)
	toolClone:SetAttribute("PackageType", deliveryData.Type)
	toolClone:SetAttribute("ToolTemplateName", toolName)

	toolClone.Parent = backpack
end

local function removeToolForDelivery(player, deliveryId, deliveryData)
	local expectedToolName = nil

	if type(deliveryData) == "table" then
		expectedToolName = getToolNameFromDelivery(deliveryData)
	end

	local function removeFrom(container)
		if not container then
			return
		end

		-- Removes tools that match this delivery
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				local matchesDeliveryId = child:GetAttribute("DeliveryId") == deliveryId
				local matchesToolName = expectedToolName and child.Name == expectedToolName

				if matchesDeliveryId or matchesToolName then
					child:Destroy()
				end
			end
		end
	end

	removeFrom(player:FindFirstChild("Backpack"))
	removeFrom(player.Character)
	removeFrom(player:FindFirstChild("StarterGear"))
end

local function syncPlayerToolsToDeliveries(player)
	local deliveries = DataManager.Get(player, "Get", "CurrentDeliveries")
	if type(deliveries) ~= "table" then
		return
	end

	local validIds = {}

	-- Makes sure every active delivery has a tool
	for deliveryId, deliveryData in pairs(deliveries) do
		validIds[deliveryId] = true
		giveToolForDelivery(player, deliveryId, deliveryData)
	end

	local function cleanup(container)
		if not container then
			return
		end

		-- Removes old delivery tools that no longer belong to the player
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				local deliveryId = child:GetAttribute("DeliveryId")
				if deliveryId and not validIds[deliveryId] then
					child:Destroy()
				end
			end
		end
	end

	cleanup(player:FindFirstChild("Backpack"))
	cleanup(player.Character)
end

local function waitAndSyncPlayerTools(player)
	task.spawn(function()
		-- Gives data and backpack a moment to load before syncing tools
		for _ = 1, 20 do
			if not player or not player.Parent then
				return
			end

			local deliveries = DataManager.Get(player, "Get", "CurrentDeliveries")
			local backpack = player:FindFirstChild("Backpack")

			if type(deliveries) == "table" and backpack then
				syncPlayerToolsToDeliveries(player)
				return
			end

			task.wait(0.5)
		end
	end)
end

local function startDeliveryTimerLoop(player)
	-- Stops multiple timer loops from being created for the same player
	if activeTimerLoops[player] then
		return
	end

	activeTimerLoops[player] = true

	task.spawn(function()
		while activeTimerLoops[player] and player.Parent do
			task.wait(1)

			local deliveries = DataManager.Get(player, "Get", "CurrentDeliveries")
			if type(deliveries) ~= "table" then
				continue
			end

			local changed = false
			local expiredIds = {}

			-- Counts down delivery timers once per second
			for deliveryId, deliveryData in pairs(deliveries) do
				if type(deliveryData) == "table" and type(deliveryData.RemainingTime) == "number" then
					deliveryData.RemainingTime -= 1
					changed = true

					-- Marks deliveries that have run out of time
					if deliveryData.RemainingTime <= 0 then
						table.insert(expiredIds, deliveryId)
					end
				end
			end

			-- Removes expired deliveries and their tools
			for _, deliveryId in ipairs(expiredIds) do
				local expiredDeliveryData = deliveries[deliveryId]
				deliveries[deliveryId] = nil
				removeToolForDelivery(player, deliveryId, expiredDeliveryData)
			end

			-- Saves changes only if something actually changed
			if changed then
				DataManager.Update(player, "CurrentDeliveries", deliveries, "Set")
			end
		end

		activeTimerLoops[player] = nil
	end)
end

local function givePackageToPlayer(player)
	local deliveries = DataManager.Get(player, "Get", "CurrentDeliveries") or {}

	-- Stops giving more packages if the limit is reached
	if getDeliveryCount(deliveries) >= MAX_DELIVERIES then
		return
	end

	-- Creates a random package from the pool
	local package = packagePool:CreateRandomPackage()
	local deliveryData = makeDeliveryData(package)
	if not deliveryData then
		return
	end

	-- Saves the delivery and gives the matching tool
	DataManager.InsertDelivery(player, deliveryData.Id, deliveryData)
	giveToolForDelivery(player, deliveryData.Id, deliveryData)

	-- Makes sure the countdown loop is running
	startDeliveryTimerLoop(player)
end

local function onPromptTriggered(prompt, player)
	if not player then
		return
	end

	playerPromptDebounce[player] = playerPromptDebounce[player] or {}

	-- Blocks repeated prompt triggers for a short time
	if playerPromptDebounce[player][prompt] then
		return
	end

	playerPromptDebounce[player][prompt] = true

	givePackageToPlayer(player)

	task.delay(PICKUP_DEBOUNCE_TIME, function()
		if playerPromptDebounce[player] then
			playerPromptDebounce[player][prompt] = nil
		end
	end)
end

local function connectPrompt(instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end

	-- Prevents the same prompt from being connected twice
	if instance:GetAttribute("PickupPromptConnected") then
		return
	end

	instance:SetAttribute("PickupPromptConnected", true)

	instance.Triggered:Connect(function(player)
		onPromptTriggered(instance, player)
	end)
end

local function findDeliverableForHouse(player, houseTag, houseIndex)
	local deliveries = DataManager.Get(player, "Get", "CurrentDeliveries")
	if type(deliveries) ~= "table" then
		return nil, nil
	end

	-- Looks for a delivery assigned to this exact house
	for deliveryId, deliveryData in pairs(deliveries) do
		if type(deliveryData) == "table" then
			if deliveryData.DestinationTag == houseTag and deliveryData.DestinationIndex == houseIndex then
				return deliveryId, deliveryData
			end
		end
	end

	return nil, nil
end

local function completeDelivery(player, deliveryId, deliveryData)
	if not deliveryId or not deliveryData then
		return
	end

	local deliveries = DataManager.Get(player, "Get", "CurrentDeliveries")
	if type(deliveries) ~= "table" then
		return
	end

	local reward = tonumber(deliveryData.Reward) or 0

	-- Removes the completed delivery from the player's active list
	deliveries[deliveryId] = nil
	DataManager.Update(player, "CurrentDeliveries", deliveries, "Set")

	-- Adds cash reward if the value is valid
	if reward > 0 then
		DataManager.Update(player, "Cash", reward, "Add")
	end

	-- Increments completed deliveries stat
	DataManager.Update(player, "Delivers", 1, "Add")

	-- Removes the package tool after delivery is finished
	removeToolForDelivery(player, deliveryId, deliveryData)
end

local function onHouseTouched(taggedAttachment, houseTag, hit)
	local character = hit.Parent
	if not character then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	local houseIndex = taggedAttachment:GetAttribute("Index")
	if type(houseIndex) ~= "number" then
		return
	end

	-- Tries to match this house to one of the player's active deliveries
	local deliveryId, deliveryData = findDeliverableForHouse(player, houseTag, houseIndex)
	if deliveryId and deliveryData then
		completeDelivery(player, deliveryId, deliveryData)
	end
end

local function connectHouseInstance(instance, houseTag)
	if not instance:IsA("Attachment") then
		return
	end

	local deliveryPart = getDeliveryPartFromTaggedInstance(instance)
	if not deliveryPart then
		return
	end

	-- Prevents duplicate touched connections on the same house part
	if deliveryPart:GetAttribute("HouseDeliveryConnected") then
		return
	end

	deliveryPart:SetAttribute("HouseDeliveryConnected", true)

	deliveryPart.Touched:Connect(function(hit)
		onHouseTouched(instance, houseTag, hit)
	end)
end

-- Connects all current tagged houses
for _, tag in ipairs(HOUSE_TAGS) do
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		connectHouseInstance(instance, tag)
	end

	-- Connects future tagged houses that get added later
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		connectHouseInstance(instance, tag)
	end)
end

-- Connects all current pickup prompts
for _, instance in ipairs(CollectionService:GetTagged("PickupPrompt")) do
	connectPrompt(instance)
end

-- Connects future pickup prompts
CollectionService:GetInstanceAddedSignal("PickupPrompt"):Connect(connectPrompt)

-- Keeps tools synced whenever delivery data changes
DataManager.OnUpdate("CurrentDeliveries", function(player, value)
	if player and player.Parent and type(value) == "table" then
		syncPlayerToolsToDeliveries(player)
	end
end)

Players.PlayerAdded:Connect(function(player)
	-- Starts the timer loop when the player joins
	startDeliveryTimerLoop(player)

	player.CharacterAdded:Connect(function()
		task.wait(0.5)

		-- Re-syncs tools after respawn
		waitAndSyncPlayerTools(player)
	end)

	-- Initial sync for loaded data
	waitAndSyncPlayerTools(player)
end)

Players.PlayerRemoving:Connect(function(player)
	-- Clears runtime state when the player leaves
	activeTimerLoops[player] = nil
	playerPromptDebounce[player] = nil
end)
