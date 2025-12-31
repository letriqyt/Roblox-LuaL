-- Made my NotLetriq 
-- notletriq on discord
-- Gun system including functions and gundata
-- Raycasting a bullet 

local RunService = game:GetService("RunService")
-- Used to check whether the script is running on the server or client

local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Stores shared assets and RemoteEvents that are accessed by both server and client

local ReplicatedFirst = game:GetService("ReplicatedFirst")
-- Used to access animations early so they are loaded before gameplay starts

local UserInputService = game:GetService("UserInputService")
-- Handles player input such as key presses and mouse actions for firing and reloading

local Debris = game:GetService("Debris")
-- Automatically cleans up temporary objects like bullet holes, particles, and sounds

-- Services and shared references used throughout the gun system
local PlaySoundEvent = ReplicatedStorage.Remotes.Sounds.PlaySound 
-- RemoteEvent used to replicate gun sounds to other players

local ReplicateTracer = ReplicatedStorage.Remotes.GunEvents.ReplicateTracer
-- RemoteEvent used to replicate bullet tracers so all players can see shots

local PlayVFXEvent = ReplicatedStorage.Remotes.GunEvents.PlayVFX
-- RemoteEvent used to replicate visual effects such as muzzle flash

local bulletHoleTexture = "rbxassetid://3696144972"
-- Texture ID used for bullet hole decals on surfaces

local Animations = ReplicatedFirst.Animations
-- Folder containing all animation assets

local GunAnimations = Animations.Guns
-- Subfolder specifically for gun-related animations

local Assets = ReplicatedStorage.Assets
-- Main assets folder stored in ReplicatedStorage

local GunAssets = Assets.Guns
-- Folder containing gun models, sounds, and VFX

local Remotes = ReplicatedStorage.Remotes
-- Main remotes folder used for client-server communication

local GunEvents = Remotes.GunEvents
-- Gun-specific remote events and functions

local GunData = {} -- Creating a empty table for GunData which stores all gun configs

function GunData.GetGun(GunName) -- Function to get a gun config by name to avoid repeating loops
	for _, Gun in GunData.Guns do -- Looping through every gun inside GunData.Guns
		if Gun.Name == GunName then -- Checking if the gun name matches the requested one
			return Gun -- Returning the gun table so it can be reused elsewhere
		end
	end
end



GunData.Guns = { -- Table holding every gun and its stats
	{
		Name = "Glock17", -- Name used to match the tool name
		-- Variables below are used for attributes and gun behaviour
		FullAuto = true, -- Determines if the gun can be held down to fire
		FireRate = 0.1, -- Time between shots
		Damage = 5, -- Base damage per bullet
		Range = 300, -- Max raycast distance
		Stored = 42, -- Ammo stored outside the magazine
		Mag = 21, -- Magazine size
		HeadshotMulti = 1.5, -- Damage multiplier for headshots
		JamChance = 0.05, -- Chance for the gun to jam when firing
		RagdollChance = 0.01, -- Chance to ragdoll on hit
	}
}

function GunData.Server(player: Player, GunModel: Tool) -- Server-sided setup for the gun
	if not GunModel then return end -- Safety check to prevent errors if gun model doesn't exist
	
	local GunName = GunModel.Name -- Getting the tool name to match with GunData
	local GunConfig = GunData.GetGun(GunName) -- Fetching the gun configuration table
	
	for Attr, Value in GunConfig do -- Looping through every stat in the gun config
		-- Applying each stat as an attribute on the tool
		GunModel:SetAttribute(Attr, Value)
	end
	
	GunModel:SetAttribute("Jammed", false) -- Attribute used to check if the gun is jammed
	GunModel:SetAttribute("Slide", false) -- Attribute used to check if the slide has been pulled


	PlaySoundEvent.OnServerEvent:Connect(function(player, position, soundName)
		-- Validating data sent from the client to prevent abuse
		if typeof(position) ~= "Vector3" or typeof(soundName) ~= "string" then return end

		for _, otherPlayer in ipairs(game.Players:GetPlayers()) do
			-- Sending the sound event to every other player except the shooter
			if otherPlayer ~= player then
				PlaySoundEvent:FireClient(otherPlayer, position, soundName)
			end
		end
	end)
	
	
	ReplicateTracer.OnServerEvent:Connect(function(player, startPos, endPos)
		-- Making sure both positions are valid vectors
		if typeof(startPos) ~= "Vector3" or typeof(endPos) ~= "Vector3" then
			return
		end

		for _, otherPlayer in ipairs(game.Players:GetPlayers()) do
			-- Replicating bullet tracers so all players can see shots
			ReplicateTracer:FireClient(otherPlayer, startPos, endPos)
		end
	end)
	
	

	PlayVFXEvent.OnServerEvent:Connect(function(player, position, vfxName)
		-- Validating VFX data sent from client
		if typeof(position) ~= "Vector3" or typeof(vfxName) ~= "string" then
			return
		end

		for _, otherPlayer in ipairs(game.Players:GetPlayers()) do
			-- Replicating visual effects to other players
			if otherPlayer ~= player then
				PlayVFXEvent:FireClient(otherPlayer, position, vfxName)
			end
		end
	end)
end

function GunData.Client(player: Player, GunModel: Tool) -- Client-sided logic for handling gun behaviour
	if RunService:IsServer() then
		-- If this somehow runs on the server, redirect it to the client
		GunEvents.Client:FireClient(player, GunModel)
		return
	end
	
	local Character = player.Character -- Reference to the player's character
	local Humanoid = Character:FindFirstChild("Humanoid") -- Used for animations
	local GunName = GunModel.Name -- Tool name
	local Tracks = {} -- Table to store animation tracks
	local Sounds = {} -- Table to store cloned gun sounds
	local VFX = {} -- Table to store visual effects
	local LastFireTime = 0 -- Used to control fire rate
	
	local PlayerGui = player.PlayerGui -- Player UI
	local GunInfo = PlayerGui.GunInfo -- Gun info screen GUI
	local Display = GunInfo.Display -- Main display frame
	local Mouse = player:GetMouse() -- Mouse reference for aiming
	
	local GunConfig = GunData.GetGun(GunName) -- Fetching gun config
	local IntialMag = GunModel:GetAttribute("Mag") -- Initial magazine value
	
	local FireRate = GunModel:GetAttribute("FireRate") -- Fire rate from attributes
	local Range = GunModel:GetAttribute("Range") -- Bullet range
	local FullAuto = GunModel:GetAttribute("FullAuto") -- Auto fire setting

	local function UpdateAmmoUI()
		-- Updating ammo text depending on gun state
		if GunModel:GetAttribute("Jammed") == true then
			Display.Ammo.Text = "Gun is JAMMED press 'F' to unjam."
		elseif GunModel:GetAttribute("Slide") == false then
			Display.Ammo.Text = "Press 'F' to Slide the Gun"
		else
			Display.Ammo.Text = GunModel:GetAttribute("Mag") .. "/" .. GunModel:GetAttribute("Stored")
		end
	end
	
	local function LoadAnimations()
		-- Loading animations based on the gun name
		local Anims = GunAnimations:FindFirstChild(GunName)
		if not Anims then warn("No anims for: "..GunName) return end
		
		Tracks.Idle = Humanoid:LoadAnimation(Anims.Idle) -- Idle animation
		Tracks.Fire = Humanoid:LoadAnimation(Anims.Fire) -- Fire animation
		Tracks.Slide = Humanoid:LoadAnimation(Anims.Slide) -- Slide animation
		Tracks.Reload = Humanoid:LoadAnimation(Anims.Reload) -- Reload animation
	end
	
	local function LoadSounds()
		-- Loading and cloning gun sounds locally
		local GunFolder = GunAssets:FindFirstChild(GunName)
		if not GunFolder then
			warn("No gun assets for: "..GunName)
			return
		end

		local GunSounds = GunFolder:FindFirstChild("Sounds")
		if not GunSounds then
			warn("No sounds for: "..GunName)
			return
		end

		table.clear(Sounds) -- Clearing old sounds to prevent duplicates

		local gunPart = GunModel:FindFirstChild("Handle") or GunModel.PrimaryPart or GunModel:FindFirstChildWhichIsA("BasePart")
		if not gunPart then
			warn("Gun has no part to parent sounds to.")
			return
		end

		for _, soundObj in ipairs(GunSounds:GetChildren()) do
			if soundObj:IsA("Sound") then
				-- Cloning sounds so each gun instance has its own audio
				local soundClone = soundObj:Clone()
				soundClone.Parent = gunPart
				soundClone.RollOffMode = Enum.RollOffMode.Inverse
				soundClone.MaxDistance = 150
				soundClone.EmitterSize = 1
				soundClone.Volume = 1
				Sounds[soundObj.Name] = soundClone
			end
		end

		local function LoadVFX()
			-- Finding the gun folder again to load particle effects
			local GunFolder = GunAssets:FindFirstChild(GunName)
			if not GunFolder then
				warn("No gun assets for:", GunName)
			return
		end

		-- Getting the VFX folder for this gun
		local GunFX = GunFolder:FindFirstChild("VFX")
		if not GunFX then
			warn("No VFX for:", GunName)
			return
		end
		
		-- Clearing previous VFX so effects don't duplicate
		table.clear(VFX)

		-- Finding a valid part on the gun to attach the VFX to
		local gunPart =
			GunModel:FindFirstChild("Handle")
			or GunModel.PrimaryPart
			or GunModel:FindFirstChildWhichIsA("BasePart")

		if not gunPart then
			warn("Gun has no part to parent VFX to.")
			return
		end

		for _, fx in ipairs(GunFX:GetChildren()) do
			if fx:IsA("ParticleEmitter") then
				-- Cloning the particle emitters so they are local per gun
				local clone = fx:Clone()
				clone.Enabled = false -- Disabled by default until fired
				clone.Parent = gunPart
				VFX[fx.Name] = clone -- Stored for easy access later
			end
		end
	end



	local function PlayGunVFX(vfxName)
		-- Playing local muzzle or gun VFX instantly
		local emitter = VFX[vfxName]
		if emitter then
			emitter:Emit(emitter:GetAttribute("EmitCount") or 1)
		end

		-- Sending the VFX event to the server so other players can see it
		PlayVFXEvent:FireServer(
			GunModel:GetPivot().Position,
			vfxName
		)
	end
	


	local function PlayWorldDust(rayResult)
		-- Creating impact effects when bullets hit the environment
		local hitPart = rayResult.Instance
		if not hitPart or not hitPart:IsA("BasePart") then return end

		local normal = rayResult.Normal -- Surface normal of the hit
		local position = rayResult.Position -- Position of the hit

		-- Proxy part used to correctly orient decals and particles
		local proxy = Instance.new("Part")
		proxy.Size = Vector3.new(0.5, 0.5, 0.01)
		proxy.Anchored = true
		proxy.CanCollide = false
		proxy.CanQuery = false
		proxy.CanTouch = false
		proxy.Transparency = 1

		-- Rotating the proxy to face away from the surface
		proxy.CFrame = CFrame.lookAt(position, position + normal)

		-- Slight offset to prevent Z messing up
		proxy.CFrame += normal * 0.01

		proxy.Parent = workspace.Debris

		-- Bullet hole decal placed on the surface
		local decal = Instance.new("Decal")
		decal.Texture = bulletHoleTexture
		decal.Face = Enum.NormalId.Front
		decal.Parent = proxy

		-- Dust particles that take the colour of the hit surface
		local dust = VFX.Dust:Clone()
		dust.Parent = proxy
		dust.Color = ColorSequence.new(hitPart.Color)

		-- Spark particles for harder surfaces
		local spark = VFX.Spark:Clone()
		spark.Parent = proxy

		dust:Emit(2)
		spark:Emit(10)

		-- Automatically cleaning up the proxy after the effect finishes
		Debris:AddItem(proxy, math.max(dust.Lifetime.Max, 5))
	end



	local function PlayEnemyVFX(vfxName, rayResult)
		-- Handling bullet impacts on characters or NPCs
		if not rayResult then return end

		local hitPart = rayResult.Instance
		if not hitPart or not hitPart:IsA("BasePart") then return end

		local character = hitPart:FindFirstAncestorOfClass("Model")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if humanoid then
			-- BLOOD effect when hitting a humanoid
			local blood = VFX.Blood:Clone()
			blood.Parent = hitPart

			if blood:IsA("ParticleEmitter") then
				-- Getting the emitcount or setting it to 5 as a base value 
				blood:Emit(blood:GetAttribute("EmitCount") or 5)
				Debris:AddItem(blood, blood.Lifetime.Max)
			end
		else
			-- If it's not a humanoid, treat it as world geometry
			PlayWorldDust(rayResult)
		end
	end


	local function PlayGunSound(soundName)
		-- Playing the sound locally for instant feedback
		local sound = Sounds[soundName]
		if sound then
			sound:Play() -- local player hears it instantly
		end

		-- Sending sound data to server for replication
		PlaySoundEvent:FireServer(GunModel:GetPivot().Position, soundName)
	end

	
	PlaySoundEvent.OnClientEvent:Connect(function(position, soundName)
		-- Receiving replicated gun sounds from other players
		local template = Sounds[soundName]
		if not template then return end

		-- Attachment is used so sound can exist in world space
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = position
		attachment.Parent = workspace.Terrain

		-- Cloning the sound so it plays at the correct position
		local soundClone = template:Clone()
		soundClone.Parent = attachment
		soundClone:Play()

		-- Cleaning up the attachment after the sound finishes
		game:GetService("Debris"):AddItem(attachment, soundClone.TimeLength)
	end)


	-- Loading all required assets once the client setup starts
	LoadAnimations()
	LoadSounds()
	LoadVFX()
	
	
	GunModel.Equipped:Connect(function()
		-- Playing idle animation when gun is equipped
		Tracks.Idle:Play()
		GunModel:SetAttribute("Equipped", true)
		
		-- Enabling gun UI
		Display.Visible = true
		Display.GunName.Text = GunName
		
		-- Resetting slide state when equipping the gun
		GunEvents.Server:InvokeServer(GunModel, {Modification = "Slide", Slide = false})
		
		UpdateAmmoUI()
	end)

	GunModel.Unequipped:Connect(function()
		-- Stopping animations and hiding UI when gun is unequipped
		Tracks.Idle:Stop()
		GunModel:SetAttribute("Equipped", false)
		
		Display.Visible = false
	end)

		UserInputService.InputBegan:Connect(function(input, gpe)
		-- Prevents input from firing if the player is typing or using UI
		if gpe then return end

		-- Handling slide pull when pressing F and the gun is not slid yet
		if input.KeyCode == Enum.KeyCode.F and GunModel:GetAttribute("Equipped") and not GunModel:GetAttribute("Slide") then
			Tracks.Slide:Play() -- Playing slide animation
			PlayGunSound("SlideSound") -- Playing slide sound
			
			-- Telling the server the slide has been pulled
			GunEvents.Server:InvokeServer(GunModel, {Modification = "Slide", Slide = true})
			UpdateAmmoUI() -- Updating UI after slide
		end
		
		-- Handling unjamming when gun is jammed and slide is already pulled
		if input.KeyCode == Enum.KeyCode.F
			and GunModel:GetAttribute("Equipped")
			and GunModel:GetAttribute("Slide")
			and GunModel:GetAttribute("Jammed") then
			
			Tracks.Slide:Play() -- Reusing slide animation for unjamming
			PlayGunSound("SlideSound") -- Same sound effect
			
			-- Sending request to server to unjam the gun
			GunEvents.Server:InvokeServer(GunModel, {Modification = "Jammed", Jammed = false})
	
			UpdateAmmoUI()
		end
		
		-- Handling reload input
		if input.KeyCode == Enum.KeyCode.R
			and GunModel:GetAttribute("Equipped")
			and GunModel:GetAttribute("Slide")
			and GunModel:GetAttribute("Mag") < IntialMag
			and GunModel:GetAttribute("Stored") > 0
			and not GunModel:GetAttribute("Reloading") then

			GunModel:SetAttribute("Reloading", true) -- Prevents firing while reloading
			Tracks.Reload:Play() -- Playing reload animation
			PlayGunSound("ReloadSound") -- Playing reload sound

			-- Sending reload request to server
			GunEvents.Server:InvokeServer(GunModel, {
				Modification = "Reload",
				IntialMag = IntialMag
			})

			-- Resetting reload state once animation finishes
			Tracks.Reload.Stopped:Once(function()
				GunModel:SetAttribute("Reloading", false)
				UpdateAmmoUI()
			end)
		end
	end)
	

	local function FireGun()
		-- Prevents firing if slide has not been pulled
		if not GunModel:GetAttribute("Slide") then return end
		
		-- Prevents firing while reloading
		if GunModel:GetAttribute("Reloading") then return end
		
		-- Handles empty magazine
		if GunModel:GetAttribute("Mag") <= 0 then
			PlayGunSound("EmptyMag")
			return
		end
		
		-- Prevents firing if player is dead
		if Character:FindFirstChild("Humanoid").Health <= 0 then return end
		
		-- Prevents firing if gun is jammed
		if GunModel:GetAttribute("Jammed") then return end

		-- Fire rate control using time difference
		local currentTime = os.clock()
		if currentTime - LastFireTime < FireRate then return end
		LastFireTime = currentTime

		-- Getting the point where bullets originate from
		local FirePoint = GunModel.Handle:FindFirstChild("GunFirePoint")
		if not FirePoint then warn("No fire point for: "..GunName) return end

		local startPosition = FirePoint.WorldPosition -- Bullet start position
		local mouseHitPosition = Mouse.Hit.Position -- Where the player is aiming
		local direction = (mouseHitPosition - startPosition).Unit -- Normalised direction
		local range = GunModel:GetAttribute("Range") -- Bullet range

		-- Setting up raycast filter to ignore the player and debris
		local filter = RaycastParams.new()
		filter.FilterDescendantsInstances = {Character, workspace.Debris}
		filter.FilterType = Enum.RaycastFilterType.Exclude

		-- Performing raycast to detect hits
		local rayResult = workspace:Raycast(startPosition, direction * range, filter)
		local endPosition = rayResult and rayResult.Position or (startPosition + direction * range)

		-- Sending fire request to server (damage, ammo, jam logic handled server side)
		local success, jammed = GunEvents.Server:InvokeServer(GunModel, {
			Modification = "Fire",
			Target = rayResult and rayResult.Instance
		})

		GunModel:SetAttribute("Jammed", jammed)
		UpdateAmmoUI()

		-- Handling jammed gun
		if jammed then
			PlayGunSound("EmptyMag")
			return
		end

		-- Replicating tracer to other clients
		ReplicateTracer:FireServer(startPosition, endPosition)

		-- Playing hit effects if something was hit
		if rayResult then
			PlayEnemyVFX("Hit", rayResult)
		end

		Tracks.Fire:Play() -- Fire animation
		PlayGunVFX("Muzzle") -- Muzzle flash
		PlayGunVFX("Spark") -- Spark effect
		PlayGunSound("ShootSound") -- Gunshot sound
		UpdateAmmoUI()
	end

	

	local function CreateTracer(startPosition, endPosition)
		-- Creating a visible tracer between start and end points
		local distance = (endPosition - startPosition).Magnitude

		local tracer = Instance.new("Part")
		tracer.CanQuery = false
		tracer.Anchored = true
		tracer.CanCollide = false
		tracer.Material = Enum.Material.Neon
		tracer.Color = Color3.fromRGB(255, 255, 0)
		tracer.Size = Vector3.new(0.3, 0.3, distance)
		tracer.CFrame = CFrame.lookAt(startPosition, endPosition) * CFrame.new(0, 0, -distance / 2)
		tracer.Parent = workspace.Debris

		-- Removing tracer shortly after creation
		Debris:AddItem(tracer, 0.15)
	end
	

	ReplicateTracer.OnClientEvent:Connect(CreateTracer)
	-- Listening for tracer replication from the server


	PlayVFXEvent.OnClientEvent:Connect(function(position, vfxName)
		-- Receiving replicated VFX from the server
		local template = VFX[vfxName]
		if not template then return end

		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = position
		attachment.Parent = workspace.Terrain

		local emitter = template:Clone()
		emitter.Parent = attachment
		emitter:Emit(emitter:GetAttribute("EmitCount") or 1)

		Debris:AddItem(attachment, 2)
	end)

	
	if FullAuto then
		-- Handling full auto firing
		local firing = false

		GunModel.Activated:Connect(function()
			firing = true
			while firing do
				FireGun()
				task.wait(FireRate)
			end
		end)

		GunModel.Deactivated:Connect(function()
			firing = false
		end)
	else
		-- Semi-auto firing
		GunModel.Activated:Connect(function()
			FireGun()
		end)
	end
	
end

	
function GunData.GiveGun(player)
	-- Gives the selected gun to the player
	if not player then return end
	
	local Hidden = player:FindFirstChild("Hidden")
	local EquippedGun = Hidden:FindFirstChild("EquippedGun").Value
	
	local GunFolder = GunAssets:FindFirstChild(EquippedGun)
	local GunClone = GunFolder:FindFirstChild(EquippedGun):Clone()
	
	GunClone.Parent = player.Backpack
	
	-- Initialising gun on server and client
	GunData.Server(player, GunClone)
	task.wait(1)
	GunData.Client(player, GunClone)
end

return GunData

	
