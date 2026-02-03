--// Core character references (bound on spawn / respawn)
local character
local humanoid
local Animator
local HumanoidRootPart
local BlockAnimTrack

--// Roblox services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local PhysicsService = game:GetService("PhysicsService")

--// Combat-related modules
local CombatChecks = require(ReplicatedStorage.Modules.Combat.CombatChecks)
local Knockback = require(ReplicatedStorage.Modules.Combat.Knockback)
local HitboxModule = require(ReplicatedStorage.Modules.Combat.Hitbox)

--// Networking
local Remotes = ReplicatedStorage.Remotes
local InputEvent = Remotes.Combat.Input
local CheckCooldown = Remotes.Other.CheckCooldown
local AnimationEvent = Remotes.Animation.AnimationEvent

--// Helper / movement / visual modules
local CooldownModule = require(ReplicatedStorage.Modules.Helpers.CooldownModule)
local SprintModule = require(ReplicatedStorage.Modules.Movement.SprintModule)
local RockModule = require(ReplicatedStorage.Modules.Visuals.RockModule)

--// Player references
local player = Players.LocalPlayer
local playerGui = player.PlayerGui
local Mouse = player:GetMouse()

--// Initial character binding
character = player.Character or player.CharacterAdded:Wait()
HumanoidRootPart = character:FindFirstChild("HumanoidRootPart")
humanoid = character:FindFirstChild("Humanoid")
Animator = humanoid:FindFirstChild("Animator")

--// Animation folders
local Animations = ReplicatedFirst.Animations
local Combat = Animations.Combat
local FightingStyle = Combat.FightingStyles
local Dashes = Combat.Dashes

--// Dash tuning constants
local DASH_START_SPEED = 60
local DASH_DECAY_RATE = 60
local BACK_DASH_PAUSE = 0.08
local BACK_DASH_BOOST = 1.0

--// Dash state
local secondFlipUsed = false
local Dashing = false
local dashBV
local dashConn
local healthConn

--// Dash trail state
local dashTrailConn
local trailActive = false
local lastTrailPos = nil
local TRAIL_SPACING = 2

--// Combat state
local Attacking = false
local Punching = false

--// Direction validation tables
local FrontBackDirections = { Front = true, Back = true }
local LeftRightDirections = { Left = true, Right = true }

--// Client module
local ClientModule = {}

--// Runtime connections & animation tracking
local Connections = {}
local AnimationHandlers = {}
local ActiveTracks = {}

--// Utility to safely disconnect named connections
local function Disconnect(name)
	if Connections[name] then
		Connections[name]:Disconnect()
		Connections[name] = nil
	end
end

--// Fetch animator from any character instance
local function getAnimator(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	return humanoid:FindFirstChildOfClass("Animator")
end

--// Check shift-lock camera state
local function IsShiftLocked()
	return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end

--// Animation replication handler (Block)
AnimationHandlers.Block = function(data)
	local character = data.Character
	local state = data.State
	if not character then return end

	local animator = getAnimator(character)
	if not animator then return end

	local style = character:GetAttribute("FightingStyle")
	if not style then return end

	local animFolder = ReplicatedFirst.Animations.Combat.FightingStyles:FindFirstChild(style)
	if not animFolder then return end

	local anim = animFolder:FindFirstChild("Block")
	if not anim then return end

	ActiveTracks[character] = ActiveTracks[character] or {}

	if state then
		if ActiveTracks[character].Block then return end

		local track = animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = true
		track:Play()

		ActiveTracks[character].Block = track
	else
		local track = ActiveTracks[character].Block
		if track then
			track:Stop(0.15)
			track:Destroy()
			ActiveTracks[character].Block = nil
		end
	end
end

--// Central animation dispatcher
AnimationEvent.OnClientEvent:Connect(function(action, data)
	local handler = AnimationHandlers[action]
	if handler then
		handler(data)
	else
		warn("No animation handler for:", action)
	end
end)

--// Auto-repeat M1 while holding punch input
task.spawn(function()
	while task.wait() do
		if Punching then
			ClientModule.M1()
		end
	end
end)

--// Rebind all character-dependent references on respawn
local function bindCharacter(char)
	character = char
	humanoid = character:WaitForChild("Humanoid")
	Animator = humanoid:WaitForChild("Animator")
	HumanoidRootPart = character:WaitForChild("HumanoidRootPart")

	Attacking = false
	Punching = false
end

--// Spawn rock trail during dash movement
local function TrySpawnDashTrail()
	if not Dashing or not dashBV then return end
	if dashBV.Velocity.Magnitude < 1 then return end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	rayParams.FilterDescendantsInstances = { character }

	local origin = HumanoidRootPart.Position
	local ray = workspace:Raycast(origin, Vector3.new(0, -12, 0), rayParams)
	if not ray then return end

	local groundPos = ray.Position - Vector3.new(0, 0.15, 0)
	if lastTrailPos and (groundPos - lastTrailPos).Magnitude < TRAIL_SPACING then return end
	lastTrailPos = groundPos

	local cf = CFrame.lookAt(groundPos, groundPos + dashBV.Velocity.Unit)

	RockModule.Trail(cf, TRAIL_SPACING, 1, 2, 0.35, false, {
		Material = ray.Instance.Material,
		Color = ray.Instance.Color
	})
end

--// Stop trail emission and cleanup
local function StopDashTrail()
	trailActive = false
	if dashTrailConn then
		dashTrailConn:Disconnect()
		dashTrailConn = nil
	end
end

--// Determine finisher based on jump / fall state
local function checkFinal()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local spaceHeld = humanoid.Jump
	local mouseHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
	local falling = humanoid:GetState() == Enum.HumanoidStateType.Freefall

	if spaceHeld and mouseHeld and not falling then
		return "Uppercut"
	end

	if falling then
		return "Downslam"
	end
end

--// Primary melee attack (M1 / combo system)
function ClientModule.M1()
	if not CombatChecks.CanM1(character) then return end
	if Attacking then return end

	local combo = character:GetAttribute("Combo") or 1
	local styleFolder = FightingStyle:FindFirstChild(character:GetAttribute("FightingStyle"))
	if not styleFolder then return end

	Attacking = true

	--// Combo finisher handling
	if combo == 4 then
		local finisher = checkFinal()
		if finisher then
			local anim = styleFolder:FindFirstChild(finisher)
			if not anim then Attacking = false return end

			local track = Animator:LoadAnimation(anim)
			Disconnect(finisher)
			track:Play(nil, nil, 1.1)

			InputEvent:InvokeServer(finisher, { Stage = "Start" })

			Connections[finisher] = track:GetMarkerReachedSignal("Hit"):Connect(function()
				HitboxModule.CreateHitbox(
					HumanoidRootPart,
					CFrame.new(0, 0, -2.5),
					Vector3.new(4, 5, 5),
					0.15,
					false,
					nil,
					function(enemies)
						if enemies and #enemies > 0 then
							InputEvent:InvokeServer(finisher, { Enemy = enemies, Stage = "Hit" })
						end
					end
				)
			end)

			SprintModule.SuppressSprint(true)
			track.Stopped:Connect(function() Attacking = false end)
			return
		end
	end

	--// Standard combo attack
	local anim = styleFolder:FindFirstChild(combo)
	if not anim then Attacking = false return end

	local track = Animator:LoadAnimation(anim)
	Disconnect("M1")
	track:Play(nil, nil, 1)

	InputEvent:InvokeServer("M1", { Enemy = nil, Stage = "Start" })

	Connections.M1 = track:GetMarkerReachedSignal("Hit"):Connect(function()
		HitboxModule.CreateHitbox(
			HumanoidRootPart,
			CFrame.new(0, 0, -2.5),
			Vector3.new(4, 5, 5),
			0.15,
			false,
			nil,
			function(enemies)
				if enemies and #enemies > 0 then
					InputEvent:InvokeServer("M1", { Enemy = enemies, Stage = "Hit" })
				end
			end
		)
	end)

	track.Stopped:Connect(function() Attacking = false end)
end


