-- Main combat module table
local CombatModule = {}

-- Services used for timing, storage, sounds, physics, and player access
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")

-- Required modules for cooldowns, combat validation, styles, and knockback
local CooldownModule = require(ReplicatedStorage.Modules.Helpers.CooldownModule)
local CombatChecks = require(ReplicatedStorage.Modules.Combat.CombatChecks)
local FightingStyles = require(ReplicatedStorage.Modules.Tables.FightingStyles)
local Knockback = require(ReplicatedStorage.Modules.Combat.Knockback)

-- Remote references for animations, VFX, and SFX
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets
local AnimationEvent = Remotes.Animation.AnimationEvent

-- Folders that contain combat visual and sound effects
local VFXFolder = Assets.VFX
local SFXFolder = SoundService.Combat

-- Tracks currently active attacks per character
local activeAttacks = {}

-- Stores last attack time per character to reset combos
local lastTimedAttack = {}

-- Stores heartbeat connections used for combo resets
local resetTimers = {}

-- Example cooldown value (not used directly here)
local M2_Cooldown = 1

-- Adds a value onto an existing attribute instead of overwriting it
local function AddAttribute(Character, Attribute, Value)
	-- Gets current attribute value and adds to it
	Character:SetAttribute(Attribute, Character:GetAttribute(Attribute) + Value)
end

-- Ensures a table exists at a given key and returns it
local function ensureTable(tbl, key)
	-- Create table if missing
	if not tbl[key] then
		tbl[key] = {}
	end
	-- Return ensured table
	return tbl[key]
end

-- Gets VFX and SFX folders based on the character’s fighting style
local function GetEffects(Character)
	-- Read the FightingStyle attribute
	local FightingStyle = Character:GetAttribute("FightingStyle")
	-- Find matching VFX folder
	local CombatVFX = VFXFolder:FindFirstChild(FightingStyle)
	-- Find matching SFX folder
	local CombatSFX = SFXFolder:FindFirstChild(FightingStyle)
	-- Return both folders
	return CombatVFX, CombatSFX
end

-- Checks if a hit is valid based on distance and facing direction
function CombatModule.CheckHit(character, enemy, sanityDistance)
	-- Cancel if either character is missing
	if not character then return end
	if not enemy then return end

	-- Get humanoid root parts for position and facing checks
	local CharHRP = character:WaitForChild("HumanoidRootPart")
	local EnemyHRP = enemy:WaitForChild("HumanoidRootPart")

	-- Calculate distance between the two characters
	local Distance = (EnemyHRP.Position - CharHRP.Position).Magnitude

	-- Fail hit if too far away
	if Distance > sanityDistance then
		print("too far away")
		return
	end

	-- Get the forward direction of the attacker
	local CharLookVector = CharHRP.CFrame.LookVector

	-- Get direction vector pointing from attacker to enemy
	local Direction = (EnemyHRP.Position - CharHRP.Position).Unit

	-- Dot product determines if attacker is facing enemy
	local DotProduct = CharLookVector:Dot(Direction)

	-- Fail hit if attacker is not facing enemy enough
	if DotProduct < 0.3 then
		print("not facing enemy")
		return
	end

	-- Hit is valid
	return true
end

-- Handles basic M1 combo attacks
function CombatModule.M1(character, enemy, stage)
	-- Stop if character is missing
	if not character then return end

	-- Current timestamp for combo timing
	local now = os.clock()

	-- Ensure attack state table exists for this character
	local active = ensureTable(activeAttacks, character)

	-- Get fighting style data
	local Style = FightingStyles.Styles[character:GetAttribute("FightingStyle")]
	if not Style then return end

	-- When M1 is pressed
	if stage == "Start" then
		-- Check if character is allowed to M1
		if not CombatChecks.CanM1(character) then return end

		-- Save the time of this attack
		lastTimedAttack[character] = now

		-- Start combo reset timer if one isn’t running
		if not resetTimers[character] then
			resetTimers[character] = RunService.Heartbeat:Connect(function()
				-- Reset combo if player waited too long
				if os.clock() - lastTimedAttack[character] > 2 then
					character:SetAttribute("Combo", 1)
					resetTimers[character]:Disconnect()
					resetTimers[character] = nil
				end
			end)
		end

		-- Get current combo or default to 1
		local Combo = character:GetAttribute("Combo") or 1

		-- Get M1 data for current combo
		local M1_Data = Style.M1_Data[Combo] or Style.M1_Data[1]

		-- Apply attack cooldown
		AddAttribute(character, "M1_CD", M1_Data.M1_CD)

		-- Apply jump lock if needed
		character:SetAttribute("NoJump", M1_Data.NoJump)

		-- Mark M1 as active
		active.M1 = now

		-- Increment combo
		Combo += 1

		-- Reset combo and apply guardbreak if max reached
		if Combo > 4 then
			AddAttribute(character, "Guardbroken", 0.8)
			Combo = 1
		end

		-- Save combo value
		character:SetAttribute("Combo", Combo)

	-- When hitbox connects
	elseif stage == "Hit" and enemy and enemy:FindFirstChild("Humanoid") then
		-- Stop if attacker is stunned
		if character:GetAttribute("Hitstun") > 0 then return end

		-- Stop if enemy cannot be damaged
		if CombatChecks.CanDamage(enemy) then return end

		-- Disable sprint on enemy when hit
		enemy:SetAttribute("SprintDisabled", true)

		-- Make sure attack timing is valid
		if not active.M1 or now - active.M1 > 0.6 then return end
		active.M1 = nil

		-- Validate distance and facing
		if not CombatModule.CheckHit(character, enemy, 10) then return end

		-- Determine which combo stage actually hit
		local Combo = character:GetAttribute("Combo")
		local M1_Data = Style.M1_Data[Combo - 1] or Style.M1_Data[4]

		-- Get humanoids and root parts
		local EnemyHumanoid = enemy:FindFirstChild("Humanoid")
		local EnemyHRP = enemy:FindFirstChild("HumanoidRootPart")
		local CharHRP = character:FindFirstChild("HumanoidRootPart")

		-- Apply damage
		EnemyHumanoid:TakeDamage(M1_Data.Damage or 5)

		-- Apply hitstun
		enemy:SetAttribute("Hitstun", M1_Data.Hitstun)

		-- Direction from attacker to enemy
		local Direction = (EnemyHRP.Position - CharHRP.Position).Unit

		-- Knockback duration
		local KnockbackDuration = 0.25

		-- Get effects
		local CombatVFX = GetEffects(character)

		-- Final hit logic
		if Combo == 1 then
			character:SetAttribute("Guardbroken", 0)

			-- Spawn final hit VFX
			local VFX = CombatVFX["FinalM1"]:Clone()
			VFX.Parent = EnemyHRP
			Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)

			-- Strong knockback
			Knockback.Standard(
				EnemyHRP,
				(Direction * 30) + Vector3.new(0, 20, 0),
				KnockbackDuration,
				1,
				Vector3.new(40000, 40000, 40000)
			)

			-- Small sprint lock
			AddAttribute(character, "Sprint_CD", 0.15)
		else
			-- Normal hit VFX
			local VFX = CombatVFX["M1"]:Clone()
			VFX.Parent = EnemyHRP
			Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)

			-- Light knockback
			Knockback.Standard(
				EnemyHRP,
				Direction * 10,
				KnockbackDuration,
				nil,
				Vector3.new(2000, 0, 20000)
			)
		end

		-- Small recoil on attacker
		Knockback.Standard(
			CharHRP,
			Direction * 10,
			KnockbackDuration,
			nil,
			Vector3.new(2000, 0, 20000)
		)
	end
end

-- return module
return CombatModule
