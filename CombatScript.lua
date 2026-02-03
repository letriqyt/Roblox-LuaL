-- Main combat module table
local CombatModule = {}

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")

--// Modules
local CooldownModule = require(ReplicatedStorage.Modules.Helpers.CooldownModule)
local CombatChecks = require(ReplicatedStorage.Modules.Combat.CombatChecks)
local FightingStyles = require(ReplicatedStorage.Modules.Tables.FightingStyles)
local Knockback = require(ReplicatedStorage.Modules.Combat.Knockback)

--// Remotes & Assets
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets
local AnimationEvent = Remotes.Animation.AnimationEvent

--// VFX / SFX folders
local VFXFolder = Assets.VFX
local SFXFolder = SoundService.Combat

--// Runtime state
local DashAxis
local activeAttacks = {}      -- Tracks active attacks per character
local lastTimedAttack = {}   -- Used for combo reset timing
local resetTimers = {}       -- Heartbeat connections for combo resets

local M2_Cooldown = 1

--// Utility: safely add to a numeric attribute
local function AddAttribute(Character, Attribute, Value)
	Character:SetAttribute(Attribute, Character:GetAttribute(Attribute) + Value)
end

--// Utility: ensure a table exists at a key
local function ensureTable(tbl, key)
	if not tbl[key] then
		tbl[key] = {}
	end
	return tbl[key]
end

--// Get player from character model
local function getPlayerFromCharacter(character)
	return Players:GetPlayerFromCharacter(character)
end

--// Handles single enemy or table of enemies uniformly
local function ForEachEnemy(enemyInput, callback)
	if not enemyInput then return end

	-- Single enemy
	if typeof(enemyInput) == "Instance" then
		callback(enemyInput)
		return
	end

	-- Multiple enemies
	if typeof(enemyInput) == "table" then
		for _, enemy in ipairs(enemyInput) do
			if typeof(enemy) == "Instance" then
				callback(enemy)
			end
		end
	end
end

--// Get combat VFX/SFX based on fighting style
local function GetEffects(Character)
	local FightingStyle = Character:GetAttribute("FightingStyle")
	local CombatVFX = VFXFolder:FindFirstChild(FightingStyle)
	local CombatSFX = SFXFolder:FindFirstChild(FightingStyle)

	return CombatVFX, CombatSFX
end

--// Fire animation event (client-specific or global)
local function FireAnimation(character, action, data)
	data = data or {}
	data.Character = character

	local player = Players:GetPlayerFromCharacter(character)

	if player then
		AnimationEvent:FireClient(player, action, data)
	else
		AnimationEvent:FireAllClients(action, data)
	end
end

----------------------------------------------------------------
-- M1 COMBO ATTACK
----------------------------------------------------------------
function CombatModule.M1(character, enemy, stage)
	if not character then return end

	local now = os.clock()
	local active = ensureTable(activeAttacks, character)

	-- Get fighting style data
	local Style = FightingStyles.Styles[character:GetAttribute("FightingStyle")]
	if not Style then return end

	----------------------------------------------------------------
	-- START PHASE
	----------------------------------------------------------------
	if stage == "Start" then
		if not CombatChecks.CanM1(character) then return end

		-- Track last attack time for combo reset
		lastTimedAttack[character] = now

		-- Heartbeat-based combo reset after inactivity
		if not resetTimers[character] then
			resetTimers[character] = RunService.Heartbeat:Connect(function()
				if os.clock() - lastTimedAttack[character] > 2 then
					character:SetAttribute("Combo", 1)
					resetTimers[character]:Disconnect()
					resetTimers[character] = nil
				end
			end)
		end

		-- Resolve combo index
		local Combo = character:GetAttribute("Combo") or 1
		local M1_Data = Style.M1_Data[Combo]

		-- Fallback if combo index invalid
		if not M1_Data then
			Combo = 1
			M1_Data = Style.M1_Data[Combo]
		end

		local FightingStyle = character:GetAttribute("FightingStyle")

		-- Play swing SFX
		Remotes.Visuals.SFXEvent:FireAllClients(
			"Swing",
			character:FindFirstChild("HumanoidRootPart"),
			Combo,
			FightingStyle
		)

		-- Apply cooldowns and restrictions
		AddAttribute(character, "M1_CD", M1_Data.M1_CD)
		character:SetAttribute("NoJump", M1_Data.NoJump)

		active.M1 = now

		-- Advance combo and handle finisher
		Combo += 1
		if Combo > 4 then
			AddAttribute(character, "Guardbroken", 0.8)
			Combo = 1
		end

		character:SetAttribute("Combo", Combo)

	----------------------------------------------------------------
	-- HIT PHASE
	----------------------------------------------------------------
	elseif stage == "Hit" then
		if character:GetAttribute("Hitstun") > 0 then return end
		if not active.M1 or now - active.M1 > 0.6 then return end

		active.M1 = nil

		local ComboAtHit = character:GetAttribute("Combo")
		local IsFinalM1 = (ComboAtHit == 1)

		local CharHRP = character:FindFirstChild("HumanoidRootPart")
		if not CharHRP then return end

		-- Resolve correct hit data
		local M1_Data = IsFinalM1
			and Style.M1_Data[4]
			or Style.M1_Data[ComboAtHit - 1]

		if not M1_Data then return end

		local FightingStyle = character:GetAttribute("FightingStyle")
		local CombatVFX, CombatSFX = GetEffects(character)

		-- Final hit bonus effects
		if IsFinalM1 then
			character:SetAttribute("Guardbroken", 0)
			AddAttribute(character, "Sprint_CD", 0.15)
		end

		-- Apply hit to all enemies
		ForEachEnemy(enemy, function(enemy)
			if not enemy:FindFirstChild("Humanoid") then return end
			if CombatChecks.CanDamage(enemy) then return end

			local EnemyHRP = enemy:FindFirstChild("HumanoidRootPart")
			local EnemyHumanoid = enemy:FindFirstChild("Humanoid")
			if not EnemyHRP or not EnemyHumanoid then return end

			-- Direction and block check
			local Direction = (EnemyHRP.Position - CharHRP.Position).Unit
			local DotProduct = EnemyHRP.CFrame.LookVector:Dot(Direction)
			local isBlocking = enemy:GetAttribute("Blocking")

			if isBlocking and DotProduct < 0.3 then
				Remotes.Visuals.SFXEvent:FireAllClients(
					"BlockHit",
					EnemyHRP,
					ComboAtHit,
					FightingStyle
				)
				return
			end

			-- Break block if hit from behind
			if isBlocking then
				CombatModule.Unblock(enemy)
			end

			-- Damage + hitstun
			EnemyHumanoid:TakeDamage(M1_Data.Damage or 5)
			enemy:SetAttribute("Hitstun", M1_Data.Hitstun)

			-- VFX / knockback
			if IsFinalM1 then
				local VFX = CombatVFX.FinalM1:Clone()
				VFX.Parent = EnemyHRP

				Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)
				Remotes.Visuals.SFXEvent:FireAllClients("Punch", EnemyHRP, 1, FightingStyle)

				Knockback.Standard(
					EnemyHRP,
					(Direction * 30) + Vector3.new(0, 20, 0),
					0.25,
					1,
					Vector3.new(40000, 40000, 40000)
				)
			else
				local VFX = CombatVFX.M1:Clone()
				VFX.Parent = EnemyHRP

				Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)
				Remotes.Visuals.SFXEvent:FireAllClients("Punch", EnemyHRP, ComboAtHit, FightingStyle)

				Knockback.Standard(
					EnemyHRP,
					Direction * 10,
					0.25,
					nil,
					Vector3.new(2000, 0, 20000)
				)
			end

			-- Small self-lunge
			Knockback.Standard(
				CharHRP,
				CharHRP.CFrame.LookVector * 10,
				0.25,
				nil,
				Vector3.new(2000, 0, 20000)
			)
		end)
	end
end

----------------------------------------------------------------
-- BLOCK / UNBLOCK
----------------------------------------------------------------
function CombatModule.Block(character, stage)
	if not character then return end

	character:SetAttribute("Blocking", stage)

	FireAnimation(character, "Block", {
		State = stage
	})
end

function CombatModule.Unblock(character)
	if not character then return end
	if not character:GetAttribute("Blocking") then return end

	character:SetAttribute("Blocking", false)

	FireAnimation(character, "Block", {
		State = false
	})
end

--// Return module
return CombatModule

