local CombatModule = {}


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")


local CooldownModule = require(ReplicatedStorage.Modules.Helpers.CooldownModule)
local CombatChecks = require(ReplicatedStorage.Modules.Combat.CombatChecks)
local FightingStyles = require(ReplicatedStorage.Modules.Tables.FightingStyles)
local Knockback = require(ReplicatedStorage.Modules.Combat.Knockback)
local PhysicsService = game:GetService("PhysicsService")

local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets
local AnimationEvent = Remotes.Animation.AnimationEvent


local VFXFolder = Assets.VFX
local SFXFolder = SoundService.Combat


local activeAttacks = {}
local lastTimedAttack = {}
local resetTimers = {}

local M2_Cooldown = 1

local function AddAttribute(Character, Attribute, Value)
	Character:SetAttribute(Attribute, Character:GetAttribute(Attribute) + Value)
end


local function ensureTable(tbl, key)
	if not tbl[key] then
		tbl[key] = {}
	end
	return tbl[key]
end

local function GetEffects(Character)
	local FightingStyle = Character:GetAttribute("FightingStyle")
	local CombatVFX = VFXFolder:FindFirstChild(FightingStyle)
	local CombatSFX = SFXFolder:FindFirstChild(FightingStyle) 
	

	return CombatVFX, CombatSFX
end


function CombatModule.CheckHit(character, enemy, sanityDistance)
	if not character then return end
	if not enemy then return end

	local CharacterHRP = character:FindFirstChild("HumanoidRootPart")
	local EnemyHRP = character:FindFirstChild("HumanoidRootPart")

	local CharDistance = CharacterHRP.Position
	local EnemyDistance = EnemyHRP.Position
	local Distance = (CharDistance - EnemyDistance).Magnitude

	local CharHRP = character:WaitForChild("HumanoidRootPart")
	local EnemyHRP = enemy:WaitForChild("HumanoidRootPart")

	local CharLookVector = CharHRP.CFrame.LookVector
	local Direction = (EnemyHRP.Position - CharHRP.Position).Unit
	local Distance = (EnemyHRP.Position - CharHRP.Position).Magnitude

	if Distance > sanityDistance then
		print("too far away")
		return
	end

	local DotProduct = CharLookVector:Dot(Direction)
	if DotProduct < 0.3  then
		print("not facing enemy")
		return
	end

	return true
end


function CombatModule.M1(character, enemy, stage)
	if not character then return end
	
	
	local now = os.clock()
	local active = ensureTable(activeAttacks, character)
	local Style = FightingStyles.Styles[character:GetAttribute("FightingStyle")]
	if not Style then return end

	if stage == "Start" then
		if not CombatChecks.CanM1(character) then return end

		lastTimedAttack[character] = now

		if not resetTimers[character] then
			resetTimers[character] = RunService.Heartbeat:Connect(function()
				if os.clock() - lastTimedAttack[character] > 2 then
					character:SetAttribute("Combo", 1)
					resetTimers[character]:Disconnect()
					resetTimers[character] = nil
				end
			end)
		end


		local Combo = character:GetAttribute("Combo")
		if not Combo then Combo = 1 end

		local M1_Data = Style.M1_Data[Combo]
		if not M1_Data then
			Combo = 1
			M1_Data = Style.M1_Data[Combo]
		end
		
		local M1_CD = M1_Data.M1_CD
		local NoJump = M1_Data.NoJump
		
		
		AddAttribute(character, "M1_CD", M1_CD)
		character:SetAttribute("NoJump", NoJump)

		
		if Combo == 3  then
			
			active.M1 = now

			Combo += 1
			if Combo > 4 then
				AddAttribute(character, "Guardbroken", 0.8)
				Combo = 1
			end
			character:SetAttribute("Combo", Combo)
			
			
		else
			AddAttribute(character, "NoJump", 0.5)
			active.M1 = now

			Combo += 1
			if Combo > 4 then
				AddAttribute(character, "Guardbroken", 0.8)
				Combo = 1
			end
			character:SetAttribute("Combo", Combo)
		end 

	elseif stage == "Hit" and enemy and enemy:FindFirstChild("Humanoid")  then
	
		if character:GetAttribute("Hitstun") > 0 then return end
		if CombatChecks.CanDamage(enemy) then return end
		
		enemy:SetAttribute("SprintDisabled", true)

		
		local EnemyHRP = enemy:FindFirstChild("HumanoidRootPart")
		local EnemyHumanoid = enemy:FindFirstChild("Humanoid")

		local CharHRP = character:FindFirstChild("HumanoidRootPart")
		local CharLookVector = CharHRP.CFrame.LookVector
		local EnemyLookVector = EnemyHRP.CFrame.LookVector


		local Direction = (EnemyHRP.Position - CharHRP.Position).Unit
		local DotProduct = EnemyLookVector:Dot(Direction)


		if DotProduct > 0.3 and enemy:GetAttribute("Blocking")  then
			print("hitting blocked player")
			return
		else
			--CombatModule.Unblock(enemy)
		end

		if not active.M1 or now - active.M1 > 0.6 then return end
		active.M1 = nil
		

		if not CombatModule.CheckHit(character, enemy, 10) then return end

		local Combo = character:GetAttribute("Combo")
		local M1_Data = Style.M1_Data[Combo - 1]
		if Combo == 1 then
			M1_Data = Style.M1_Data[4]
		end


		EnemyHumanoid:TakeDamage(M1_Data.Damage or 5)
		enemy:SetAttribute("Hitstun", M1_Data.Hitstun)
		
		

		local KnockbackDuration = 0.25
		local FightingStyle = character:GetAttribute("FightingStyle")
		local CombatVFX, CombatSFX = GetEffects(character)

		if Combo == 1 then 
			character:SetAttribute("Guardbroken", 0)
			local VFX = CombatVFX["FinalM1"]:Clone()
			VFX.Parent = EnemyHRP
			Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)
			Remotes.Visuals.SFXEvent:FireAllClients("Punch", EnemyHRP, Combo, FightingStyle)


			Knockback.Standard(EnemyHRP, (Direction * 30) + Vector3.new(0,20,0), KnockbackDuration, 1, Vector3.new(40000, 40000, 40000)) 
			
			AddAttribute(character, "Sprint_CD", 0.15)
			
			
		else
			
			local VFX = CombatVFX["M1"]:Clone()
			VFX.Parent = EnemyHRP
			Remotes.Visuals.VFXEvent:FireAllClients("Play", VFX, 0.3)
			Remotes.Visuals.SFXEvent:FireAllClients("Punch", EnemyHRP, Combo, FightingStyle)


			Knockback.Standard(EnemyHRP, Direction * 10, KnockbackDuration, nil, Vector3.new(2000, 0, 20000)) 
		end
		
		
	
		
		
		Knockback.Standard(CharHRP, Direction * 10, KnockbackDuration, nil, Vector3.new(2000, 0, 20000)) 


	end
end
