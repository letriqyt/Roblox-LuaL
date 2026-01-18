-- Made by Letriq
-- Main combat module table
-- Acts as a centralized server-authoritative combat handler responsible for
-- validating attacks, managing combo state, applying damage, and triggering
-- replicated audiovisual feedback
local CombatModule = {}

----------------------------------------------------------------
-- Services
-- Core Roblox services leveraged for replication, timing,
-- physics interaction, and player resolution
----------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService") -- Used for frame-accurate timing via Heartbeat
local Players = game:GetService("Players") -- Used to resolve characters to players
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris") -- Used for automatic cleanup of temporary instances
local PhysicsService = game:GetService("PhysicsService") -- Referenced for collision-layer aware combat systems

----------------------------------------------------------------
-- Required Modules
-- Modular combat architecture allows individual systems to be
-- iterated on independently without touching core combat logic
----------------------------------------------------------------
local CooldownModule = require(ReplicatedStorage.Modules.Helpers.CooldownModule)
local CombatChecks = require(ReplicatedStorage.Modules.Combat.CombatChecks)
local FightingStyles = require(ReplicatedStorage.Modules.Tables.FightingStyles)
local Knockback = require(ReplicatedStorage.Modules.Combat.Knockback)

----------------------------------------------------------------
-- Remote references
-- Used to replicate animations, VFX, and SFX to clients while
-- keeping combat logic fully server-authoritative
----------------------------------------------------------------
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets
local AnimationEvent = Remotes.Animation.AnimationEvent

----------------------------------------------------------------
-- Asset folders
-- Visual and audio feedback is resolved dynamically based on
-- the character's fighting style for data-driven extensibility
----------------------------------------------------------------
local VFXFolder = Assets.VFX
local SFXFolder = SoundService.Combat

----------------------------------------------------------------
-- Runtime combat state tracking
-- These tables persist per-character combat state without
-- relying on Value objects, favoring Attributes and Lua tables
----------------------------------------------------------------
local activeAttacks = {}     -- Tracks currently active attacks per character
local lastTimedAttack = {}  -- Used to determine combo reset windows
local resetTimers = {}      -- Stores Heartbeat connections for combo decay

----------------------------------------------------------------
-- Example cooldown (placeholder for extended moveset)
----------------------------------------------------------------
local M2_Cooldown = 1

----------------------------------------------------------------
-- Adds a numeric value onto an existing attribute instead of
-- overwriting it, enabling stacked cooldowns and state windows
-- Uses Roblox Attributes for efficient replication and clarity
----------------------------------------------------------------
local function AddAttribute(Character, Attribute, Value)
	Character:SetAttribute(Attribute, Character:GetAttribute(Attribute) + Value)
end

----------------------------------------------------------------
-- Ensures a nested table exists for a given key
-- Common defensive Lua pattern to prevent nil indexing while
-- maintaining per-entity state without object instances
----------------------------------------------------------------
local function ensureTable(tbl, key)
	if not tbl[key] then
		tbl[key] = {}
	end
	return tbl[key]
end

----------------------------------------------------------------
-- Resolves combat VFX and SFX folders based on the character’s
-- current fighting style attribute
-- Enables fully data-driven combat presentation
----------------------------------------------------------------
local function GetEffects(Character)
	local FightingStyle = Character:GetAttribute("FightingStyle")
	local CombatVFX = VFXFolder:FindFirstChild(FightingStyle)
	local CombatSFX = SFXFolder:FindFirstChild(FightingStyle)
	return CombatVFX, CombatSFX
end

----------------------------------------------------------------
-- Primary M1 combo handler
-- Handles both the input stage ("Start") and hit-confirmation
-- stage ("Hit"), enforcing timing, combo state, and validation
----------------------------------------------------------------
function CombatModule.M1(character, enemy, stage)
	-- Abort if character reference is invalid
	if not character then return end

	-- Timestamp used for frame-accurate timing windows
	local now = os.clock()

	-- Ensure combat state table exists for this character
	local active = ensureTable(activeAttacks, character)

	-- Resolve the fighting style data table
	local Style = FightingStyles.Styles[character:GetAttribute("FightingStyle")]
	if not Style then return end

	----------------------------------------------------------------
	-- Attack start logic
	----------------------------------------------------------------
	if stage == "Start" then
		-- Validate whether the character is allowed to perform M1
		if not CombatChecks.CanM1(character) then return end

		-- Store the time this attack was initiated
		lastTimedAttack[character] = now

		-- Initialize combo reset timer using RunService.Heartbeat
		-- This avoids reliance on task.wait and ensures frame-accurate decay
		if not resetTimers[character] then
			resetTimers[character] = RunService.Heartbeat:Connect(function()
				if os.clock() - lastTimedAttack[character] > 2 then
					character:SetAttribute("Combo", 1)
					resetTimers[character]:Disconnect()
					resetTimers[character] = nil
				end
			end)
		end

		-- Resolve current combo count or default to 1
		local Combo = character:GetAttribute("Combo") or 1

		-- Resolve combo-specific data with safe fallback
		local M1_Data = Style.M1_Data[Combo] or Style.M1_Data[1]

		-- Apply cooldown and movement restrictions via Attributes
		AddAttribute(character, "M1_CD", M1_Data.M1_CD)
		character:SetAttribute("NoJump", M1_Data.NoJump)

		-- Mark this M1 as active for hit validation
		active.M1 = now

		-- Increment combo counter
		Combo += 1

		-- Reset combo and apply guardbreak window if max combo reached
		if Combo > 4 then
			AddAttribute(character, "Guardbroken", 0.8)
			Combo = 1
		end

		-- Persist combo state
		character:SetAttribute("Combo", Combo)

	----------------------------------------------------------------
	-- Hit confirmation logic
	----------------------------------------------------------------
	elseif stage == "Hit" and enemy and enemy:FindFirstChild("Humanoid") then
		-- Cancel hit if attacker is currently stunned
		if character:GetAttribute("Hitstun") > 0 then return end

		-- Validate attack timing window
		if not active.M1 or now - active.M1 > 0.6 then return end
		active.M1 = nil

		-- Determine which combo stage actually connected
		local Combo = character:GetAttribute("Combo")
		local M1_Data = Style.M1_Data[Combo - 1] or Style.M1_Data[4]

		-- Resolve humanoids and root parts
		local EnemyHumanoid = enemy:FindFirstChild("Humanoid")
		local EnemyHRP = enemy:FindFirstChild("HumanoidRootPart")
		local CharHRP = character:FindFirstChild("HumanoidRootPart")

		-- Apply damage server-side to prevent exploitation
		EnemyHumanoid:TakeDamage(M1_Data.Damage or 5)

		-- Apply hitstun window via Attribute
		enemy:SetAttribute("Hitstun", M1_Data.Hitstun)

		-- Calculate directional vector for knockback physics
		local Direction = (EnemyHRP.Position - CharHRP.Position).Unit

		-- Resolve combat visual effects
		local CombatVFX = GetEffects(character)

		-- Final hit behavior
		if Combo == 1 then
			character:SetAttribute("Guardbroken", 0)

			-- Spawn final hit VFX and replicate to all clients
			local VFX = CombatVFX["FinalM1"]:Clone()
			VFX.Parent = EnemyHRP
			Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)

			-- Apply strong knockback using physics abstraction
			Knockback.Standard(
				EnemyHRP,
				(Direction * 30) + Vector3.new(0, 20, 0),
				0.25,
				1,
				Vector3.new(40000, 40000, 40000)
			)

			-- Apply sprint recovery delay
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
				0.25,
				nil,
				Vector3.new(2000, 0, 20000)
			)
		end

		-- Apply small recoil to attacker for physical feedback
		Knockback.Standard(
			CharHRP,
			Direction * 10,
			0.25,
			nil,
			Vector3.new(2000, 0, 20000)
		)
	end
end

----------------------------------------------------------------
-- Downslam handler
-- Heavy finisher attack intended to break defense and force
-- vertical displacement, executed as a special M1 variant
-- Server-authoritative to prevent exploit-based velocity abuse
----------------------------------------------------------------
function CombatModule.Downslam(character, enemy, stage)
	-- Abort immediately if character reference is invalid
	if not character then return end

	-- Timestamp used for combo decay and hit validation windows
	local now = os.clock()

	-- Ensure runtime combat state exists for this character
	local active = ensureTable(activeAttacks, character)

	-- Resolve fighting style data table
	local Style = FightingStyles.Styles[character:GetAttribute("FightingStyle")]
	if not Style then return end

	----------------------------------------------------------------
	-- Attack startup logic
	----------------------------------------------------------------
	if stage == "Start" then
		-- Prevent execution if combat state disallows attacking
		if not CombatChecks.CanM1(character) then return end

		-- Register attack start time for timing validation
		lastTimedAttack[character] = now

		-- Initialize combo reset timer if not already active
		-- Uses Heartbeat instead of task.wait for frame accuracy
		if not resetTimers[character] then
			resetTimers[character] = RunService.Heartbeat:Connect(function()
				if os.clock() - lastTimedAttack[character] > 2 then
					character:SetAttribute("Combo", 1)
					resetTimers[character]:Disconnect()
					resetTimers[character] = nil
				end
			end)
		end

		-- Resolve downslam data from style table
		local M1_Data = Style.M1_Data["Downslam"]
		if not M1_Data then return end

		-- Apply attack cooldown and movement restrictions
		AddAttribute(character, "M1_CD", M1_Data.M1_CD)
		AddAttribute(character, "NoJump", 0.6)

		-- Mark attack as active for later hit confirmation
		active.M1 = now

		-- Open a guardbreak window for the duration of the slam
		AddAttribute(character, "Guardbroken", 0.8)

		-- Downslam always resets combo state
		character:SetAttribute("Combo", 1)

	----------------------------------------------------------------
	-- Hit confirmation logic
	----------------------------------------------------------------
	elseif stage == "Hit" and enemy and enemy:FindFirstChild("Humanoid") then
		-- Cancel hit if attacker is currently stunned
		if character:GetAttribute("Hitstun") > 0 then return end

		-- Validate attack timing window
		if not active.M1 or now - active.M1 > 0.6 then return end
		active.M1 = nil

		-- Resolve humanoids and root parts
		local EnemyHumanoid = enemy:FindFirstChild("Humanoid")
		local EnemyHRP = enemy:FindFirstChild("HumanoidRootPart")
		local CharHRP = character:FindFirstChild("HumanoidRootPart")
		if not EnemyHRP or not CharHRP then return end

		-- Calculate relative direction vectors
		local Direction = (CharHRP.Position - EnemyHRP.Position).Unit
		local EnemyLookVector = EnemyHRP.CFrame.LookVector

		-- Dot product determines if enemy is facing the attack
		local DotProduct = EnemyLookVector:Dot(Direction)

		-- Block validation
		-- Enemy can block only if facing the attacker correctly
		if DotProduct > 0.3 and enemy:GetAttribute("Blocking") then
			return
		end

		-- Validate distance and hit angle
		if not CombatModule.CheckHit(character, enemy, 10) then return end

		-- Resolve downslam combat data
		local M1_Data = Style.M1_Data["Downslam"]

		-- Apply server-side damage
		EnemyHumanoid:TakeDamage(M1_Data.Damage or 5)

		-- Apply hitstun via Attributes for replication clarity
		enemy:SetAttribute("Hitstun", M1_Data.Hitstun)

		-- Resolve combat visual effects
		local CombatVFX = GetEffects(character)

		-- Clear guardbreak state on attacker
		character:SetAttribute("Guardbroken", 0)

		-- Spawn final slam VFX and replicate to clients
		local VFX = CombatVFX["FinalM1"]:Clone()
		VFX.Parent = EnemyHRP
		Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)

		-- Apply sprint recovery delay
		AddAttribute(character, "Sprint_CD", 0.15)

		-- Apply strong downward knockback
		-- Vertical force prioritized to simulate slam impact
		Knockback.Standard(
			EnemyHRP,
			(Direction * 5) + Vector3.new(0, -30, 0),
			0.25,
			1.25,
			Vector3.new(0, 400000, 0)
		)
	end
end


----------------------------------------------------------------
-- Return combat module
----------------------------------------------------------------
return CombatModule
