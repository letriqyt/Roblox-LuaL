PetHandler.OnServerInvoke = function(player, mode, dataName) -- Server responds to an InvokeServer from the client --

	local DataUpdated = ReplicatedStorage.Remotes.Data.DataUpdated -- Remote for sending information to the client for UI purposes --


	if mode == "Get" then -- Checking the mode that passed through the event --
		local PetsEquipped = DataManager.Get(player, "PetsEquipped") -- Gets the PetsEquipped table from the data (profileservice) --
		local PetsAllowed = DataManager.Get(player, "PetsAllowed") -- Gets the amount of pets allowed on the players data --
		local Inventory = DataManager.Get(player, "Inventories") -- Gets the inventory from the data --

		return PetsEquipped, PetsAllowed, Inventory -- Returns this for use on the UI on the client side --
	end



	if mode == "Buy" then -- Checking the mode that passed through the event --

		local PetInfo = PetData.GetPet(dataName) -- Getting the pet data from a table in PetData (Module) returning the values for the data passed through--
		if not PetInfo then return end -- If not found return --

		if PetData.HasPet(player, dataName) then -- Checking if the player already has the pet --
			warn("Player already owns pet") -- Warning --
			return false -- Return false to the Client --
		end

		local playerCash = DataManager.Get(player, "Cash") -- Gets the cash from the data --
		local price = PetInfo.Price -- Gets the price of the Pet --

		if not price then return false end -- If no price then error then return --

		if playerCash < price then -- If you dont have enough money spawn in the notification --
			VisualsHandler.SpawnNotification(player, "Stat", "Cash") -- Visuals handler spawning the notification --
			return false -- Dint buy --
		end

		-- Insert into inventory
		DataManager.Update( -- Update the inventory adding the new dataName --
			player,
			"Inventories",
			{
				Category = "Pets",
				Value = dataName
			},
			"Insert" -- Insert mode --
		)

		DataManager.Update(player, "Cash", -price, "Add") -- Updating the Cash data minusing the money spent --


		local newInv = DataManager.Get(player, "Inventories") -- Getting the new inventory to send to client --
		DataUpdated:FireClient(player, "Inventories", newInv) -- Sending to client --

		return true -- You have bought the pet --
	end


	
	if mode == "Equip" then -- Checking the mode that passed through the event --
 
		local inv = DataManager.Get(player, "Inventories") -- Getting Inv from Data --
		local equipped = DataManager.Get(player, "PetsEquipped") -- Getting the pets equipped from Data --
		local petsAllowed = DataManager.Get(player, "PetsAllowed") -- Getting pets allowed from Data --

		-- Must own pet --
		if not table.find(inv.Pets, dataName) then
			return false
		end

		-- Checking if its already equipped --
		if table.find(equipped, dataName) then
			return true, equipped
		end

		-- If full then remove oldest --
		if #equipped >= petsAllowed then
			table.remove(equipped, 1)
		end

		-- Equip --
		table.insert(equipped, dataName)

		DataManager.Update(player, "PetsEquipped", equipped, "Set")

		-- Give pets in workspace --
		PetData.GivePet(player, equipped)

		-- Tell client equipped pets changed --
		DataUpdated:FireClient(player, "PetsEquipped", equipped)

		return true, equipped
	end



	if mode == "Unequip" then -- Checking the mode that passed through the event --

		local equipped = DataManager.Get(player, "PetsEquipped") -- Checks the PetsEquipped on the Data
		local index = table.find(equipped, dataName) -- Finds the pet in the equipped table --

		if not index then -- If its not in there then u dont need to remove it --
			return false
		end

		table.remove(equipped, index) -- Removing it --

		DataManager.Update(player, "PetsEquipped", equipped, "Set") -- Setting the data to then change the pets on the workspace --

		-- Update workspace
		PetData.GivePet(player, equipped) -- Using the module the change the pets --

		DataUpdated:FireClient(player, "PetsEquipped", equipped) -- Firing to client to acknowledge the change on the buttons (equipped unequip esc) --

		return true, equipped -- Returning information to the client --
	end

	return false -- Returning false because no change happened --
end


SettingsHandler.OnServerInvoke = function(player, mode, dataName) -- Server responds to an InvokeServer from the client --
	if mode == "On" then -- Checking mode passed through --
		if not player then return end -- If theres no player then return --
		DataManager.Update(player, "Inventories",{Category = "Settings", Value = dataName.Name}, "Insert") -- Update player inventory so they have this setting enabled --

		SystemData.EnableSettings(player, dataName) -- Enable the setting by matching the name on the modules --
		
	end
	
	if mode == "Off" then -- Checking mode passed through --
		
		DataManager.Update(player, "Inventories",{Category = "Settings", Value = dataName.Name}, "Remove") -- Remove th
		
		SystemData.DisableSettings(player, dataName)
	end
	
	if mode == "Get" then -- Checking mode passed through --
		if table.find(DataManager.Get(player, "Inventories").Settings, dataName.Name) then -- Find the setting  --
			return true -- Return true for client --
		else
			return false -- Return false for client --
		end
		
	end
end


ItemHandler.OnServerInvoke = function(player, mode, dataName) -- Server responds to an InvokeServer from the client --

	local DataUpdated = ReplicatedStorage.Remotes.Data.DataUpdated -- Remote used to update client --

	if mode == "Get" then -- Mode passed through the remotefunction
		local Inventory = DataManager.Get(player, "Inventories") -- Inventory from data --
		return Inventory -- Return inventory for whereever it was called (client)
	end

	if mode == "Amount" then -- Mode passed through the remotefunction
		local Inventory = DataManager.Get(player, "Inventories")  -- Getting the inventory from the data

		local count = 0 -- Setting the variable --
		for _, item in pairs(Inventory.Items) do -- Looping through the itmes in inventory and checking if there the dataname if they is multiple it will add to count --
			if item == dataName then
				count += 1
			end
		end

		return count -- Returning count to identify how many items the player has --
	end

	if mode == "Use" then -- Mode passed through the remotefunction
		if not player then return end -- Needs the player for this mode --

		local itemData = dataName -- Setting itemData to have the table of values --
		local effects = DataManager.Get(player, "Effects") or {} -- Add to current efects or make a empty table --

		
		local effectKey = nil -- Setting effect key to nil
		for key, value in pairs(itemData) do -- Looping through the data
			if typeof(value) == "number" and key ~= "Time" and key ~= "Price" then
				effectKey = key -- Locating the key we want to match e.g luck or fatgain --
				break -- End the code --
			end
		end

		if not effectKey then -- if theres no key for the item in question return end --
			warn("Item has no effect field:", itemData.Name) -- Warning for debugging --
			return
		end

		local existing = effects[effectKey] -- getting the Existing key in effects

		-- already active → extend duration 
		if existing and existing.Name == itemData.Name then
			existing.Remaining += itemData.Time -- Adding the time of the new item
			DataManager.Update(player, "Effects", effects, "Set") -- Updating the effects --
			BuffHandler.StartCountdown(player, effectKey) -- Starting the countdown on the client --

			DataManager.Update(player, "Inventories", {Category = "Items", Value = itemData.Name}, "Remove") -- Removing the item from the inventory --
			return true -- Return true for the client --
		end

		
		effects[effectKey] = { -- Key template with generalised statKey and effectKey so the potion/item can have any data type --
			Amount = itemData[effectKey], -- Amount of Items --
			Remaining = itemData.Time, -- Time Remaining --
			Image = itemData.Image, -- Image ID--
			Name = itemData.Name, -- Name of item --
			EffectKey = effectKey, -- Name of the key --
			StatKey = effectKey -- Stat name --
		}

		DataManager.Update(player, "Effects", effects, "Set") -- Update the effects --

		VisualsHandler.ItemNotification(player, "Item", effects[effectKey]) -- Add the UI effect to the holder --
		ItemData.RecomputePlayerBuffs(player) -- Add the effects if its first load --
		BuffHandler.StartCountdown(player, effectKey) -- Start the countdown --

		-- remove item from inventory
		DataManager.Update(player, "Inventories", {Category = "Items", Value = itemData.Name}, "Remove")

		return true -- Return true for the client --
	end
	
end


CodesHandler.OnServerInvoke = function(player, dataName, rewards) -- Server responds to an InvokeServer from the client --
	local CodeData = DataManager.Get(player, "CodeData") -- Getting the players code data (already redeemed codes)
	if CodeData.Codes and table.find(CodeData.Codes, dataName) then  -- If they found that the code their trying to redeem is already redeemed spawn in notification --
		VisualsHandler.SpawnNotification(player, "Code") -- Client side --
	return end
	
	print("Redeemed " .. dataName) -- print for debugging --
	
	if rewards.Cash then -- If there is a .Cash value it will add it to the players cash --
		print("Found Cash Value")
		DataManager.Update(player, "Cash", rewards.Cash, "Add")
	end
	
	
	
	DataManager.Update(player, "CodeData", { -- Inserting the value into codeData so it cannot be claimed again
		Category = "Codes",
		Value = dataName}
	, "Insert")

end


RebirthHandler.OnServerInvoke = function(player, mode) -- Server responds to an InvokeServer from the client --
	if mode == "Rebirth" then -- Checks mode --
		return RebirthConfig.Rebirth(player) -- If you click rebirth on the button it will fire this rebirthing the player resetting fat and foods esc --
	end
	
	if mode == "Get" then -- Checks mode --
		return DataManager.Get(player, "Rebirths") -- returns amount of rebirths
	end
	
	return false -- Return false for client if no rebirth happened or get --
end



UseFoodEvent.OnServerEvent:Connect(function(player, tool) -- Server responds to an InvokeServer from the client --
	for _, foodValue in pairs(FoodData.Food) do -- Loops through fooddata.foods
		if foodValue.Name == tool.Name then -- Checks if the foodvalue is equal to the tool in hand --
			local character = player.Character
			
			for _, foodValue in pairs(FoodData.Food) do -- Loops through foodData.food again --
				if foodValue.Name == tool.Name then -- Checks again --
					local character = player.Character

					if CooldownModule.CheckCooldown(character.Name, "CanClick") then return end -- Checks cooldown if they can use the food (Module) --

					local FoodValue = FoodData.GetFood(tool.Name) -- Matches the food value by passing through the tool name --
					CooldownModule.AddCooldown(character.Name, "CanClick", foodValue.Cooldown) -- Adds cooldown as the event is about to run --

					EatingAnimationEvent:FireClient(player) -- Fires the animation on the client --

				
					local totalMultiplier = 1 -- Sets base multipler --

					for _, petName in pairs(DataManager.Get(player, "PetsEquipped")) do -- Loop through pets equipped --
						for _, petValues in pairs(PetData.Pets) do
							if petValues.Name == petName then -- if you have the pet the multiplier is added to total mulplier (1 + 0.2 ) esc --
								totalMultiplier += petValues.FatMultiplier
							end
						end
					end

					
					if totalMultiplier == 0 then -- if error happens and it becomes 0 then it gets set back to 1 --
						totalMultiplier = 1 
					end

					local rebirths = DataManager.Get(player, "Rebirths") -- Gets the rebirths from the data --
					local rebirthMultiplier = 1 + (rebirths * 0.10) -- Adds a multiplier for every rebirth --

					local finalGain = foodValue.FatGain  -- Calculates the final gain (multiplier) --
						* DataManager.Get(player, "FatGain") -- Fatgain from data --
						* totalMultiplier -- Total Multiplier from pets --
						* rebirthMultiplier -- rebirth multiplier --
						* 1 -- Another variable if needed --

					DataManager.Update(player, "Fat", finalGain, "Add") -- Add the fat that been calculated to the Data --
					FoodData.SetFat(player, DataManager.Get(player, "Fat")) -- Set the fat immeideitly so we can see the character get bigger --

				end
			end

		end
	end
end)
