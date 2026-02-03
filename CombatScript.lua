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

function ClientModule.Dash(Direction, isIdleDash)
	--// Direction classification
	local isFrontBack = FrontBackDirections[Direction] == true
	local isLeftRight = FrontBackDirections[Direction] == true
	local Camera = workspace.CurrentCamera

	--// Global dash checks
	if not CombatChecks.CanDash(character) then return end
	if Attacking and isFrontBack then return end
	if Dashing then return end

	--// Cooldown routing based on dash axis
	local isForward = (Direction == "Front" or Direction == "Back")
	local OnCD 

	if isForward then
		OnCD = Remotes.Other.CheckCooldown:InvokeServer(character.Name, "Forward")
		if OnCD then return end
	else
		OnCD = Remotes.Other.CheckCooldown:InvokeServer(character.Name, "Side")
		if OnCD then return end
	end

	--// Character validation
	local Humanoid = character:FindFirstChild("Humanoid")
	if not Humanoid then return end

	--// Fetch dash animations
	local DashAnim = ReplicatedFirst.Animations.Combat.Dashes:FindFirstChild(Direction)
	local FrontHit = ReplicatedFirst.Animations.Combat.Dashes.FrontHit
	if not DashAnim or not FrontHit then return end

	--// Enter dash state
	Dashing = true
	secondFlipUsed = false

	--// Rotation locking for forward dash
	local originalAutoRotate = Humanoid.AutoRotate
	local lockedYaw

	if Direction == "Front" then
		Humanoid.AutoRotate = false
		local _, yaw, _ = HumanoidRootPart.CFrame:ToEulerAnglesYXZ()
		lockedYaw = yaw
	end

	--// Play dash animation
	local animTrack = Animator:LoadAnimation(DashAnim)
	animTrack.Priority = Enum.AnimationPriority.Action
	animTrack:Play(0.05, nil, 1.1)

	--// Notify server of dash start
	InputEvent:InvokeServer("Dash", {
		Stage = "Start",
		Direction = Direction
	})

	--// Dash cancel conditions
	local startHealth = Humanoid.Health
	local cancelling = false

	--// Full dash cleanup
	local function cancelDash()
		if cancelling then return end
		cancelling = true
		if not Dashing then return end

		Dashing = false

		if dashConn then dashConn:Disconnect() dashConn = nil end
		if dashBV then dashBV:Destroy() dashBV = nil end
		if healthConn then healthConn:Disconnect() healthConn = nil end
		if animTrack and animTrack.IsPlaying then animTrack:Stop(0.1) end

		Humanoid.AutoRotate = originalAutoRotate
		lockedYaw = nil

		StopDashTrail()
	end

	--// Cancel dash on damage
	healthConn = Humanoid.HealthChanged:Connect(function(newHealth)
		if newHealth < startHealth then
			cancelDash()
		end
	end)

	--// Dash tuning per direction
	local DashStats = {
		Front = { Speed = 60, CameraSteer = false },
		Back  = { Speed = 60, CameraSteer = true },
		Left  = { Speed = 45, CameraSteer = true },
		Right = { Speed = 45, CameraSteer = true }
	}

	local Stats = DashStats[Direction]
	local dashDir

	--// Initial dash direction resolution
	local function GetInitialDashDirection()
		if Stats.CameraSteer then
			local camForward = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z).Unit
			local camRight = Vector3.new(Camera.CFrame.RightVector.X, 0, Camera.CFrame.RightVector.Z).Unit

			if Direction == "Front" then
				return camForward
			elseif Direction == "Back" then
				return -camForward
			elseif Direction == "Right" then
				return camRight
			elseif Direction == "Left" then
				return -camRight
			end
		else
			local look = HumanoidRootPart.CFrame.LookVector
			return Vector3.new(look.X, 0, look.Z).Unit
		end
	end

	--// Convert yaw to forward vector
	local function ForwardFromYaw(yaw)
		return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	end

	--// Initialize dash velocity
	dashDir = GetInitialDashDirection()

	dashBV = Instance.new("BodyVelocity")
	dashBV.MaxForce = Vector3.new(50000, 0, 50000)
	dashBV.Velocity = dashDir * DASH_START_SPEED
	dashBV.Parent = HumanoidRootPart

	local currentSpeed = DASH_START_SPEED

	--// Dash movement loop
	dashConn = RunService.RenderStepped:Connect(function(deltaTime)
		if not Dashing or not dashBV or not dashDir then return end

		--// Forward dash yaw locking
		if Direction == "Front" and lockedYaw then
			local pos = HumanoidRootPart.Position

			if IsShiftLocked() then
				local camLook = Camera.CFrame.LookVector
				lockedYaw = math.atan2(-camLook.X, -camLook.Z)
				dashDir = ForwardFromYaw(lockedYaw)
			end

			HumanoidRootPart.CFrame =
				CFrame.new(pos) *
				CFrame.fromOrientation(0, lockedYaw, 0)
		end

		--// Live camera steering
		if Stats.CameraSteer then
			dashDir = GetInitialDashDirection()
		end

		dashDir = Vector3.new(dashDir.X, 0, dashDir.Z).Unit
		dashBV.Velocity = dashDir * currentSpeed

		currentSpeed -= DASH_DECAY_RATE * deltaTime
		if currentSpeed <= 0 then
			cancelDash()
			return
		end

		TrySpawnDashTrail()
	end)

	--// Dash impact window
	animTrack:GetMarkerReachedSignal("End"):Connect(function()
		if not Dashing then return end

		local HitTrack = Animator:LoadAnimation(FrontHit)
		HitTrack.Priority = Enum.AnimationPriority.Action
		HitTrack:Play(0.05, nil, 1.1)

		InputEvent:InvokeServer("Dash", {
			Stage = "HitPoint",
			Direction = Direction
		})

		HitboxModule.CreateHitbox(
			HumanoidRootPart,
			CFrame.new(0, 0, -2.5),
			Vector3.new(4, 5, 5),
			0.15,
			false,
			nil,
			function(enemies)
				if enemies and #enemies > 0 then
					InputEvent:InvokeServer("Dash", {
						Enemy = enemies,
						Stage = "Hit"
					})
				end
			end
		)
	end)

	--// Back dash flip logic
	animTrack:GetMarkerReachedSignal("Back"):Connect(function()
		if not Dashing then return end
		if Direction ~= "Back" or secondFlipUsed then return end
		secondFlipUsed = true

		if dashBV then dashBV.Velocity = Vector3.zero end
		StopDashTrail()

		task.delay(BACK_DASH_PAUSE, function()
			if not Dashing then return end

			dashDir = GetInitialDashDirection()
			dashDir = Vector3.new(dashDir.X, 0, dashDir.Z).Unit
			currentSpeed = DASH_START_SPEED * BACK_DASH_BOOST

			if dashBV then
				dashBV.Velocity = dashDir * currentSpeed
			end

			TrySpawnDashTrail()
		end)
	end)

	--// Final cleanup on animation stop
	animTrack.Stopped:Connect(cancelDash)
end


function ClientModule.Block()
	--// Notify server of block start
	InputEvent:InvokeServer("Block", { Stage = true })

	--// Resolve block animation from fighting style
	local styleName = character:GetAttribute("FightingStyle")
	local styleFolder = FightingStyle:FindFirstChild(styleName)
	if not styleFolder then return end

	local anim = styleFolder:FindFirstChild("Block")
	if not anim then return end

	--// Replace existing block animation
	if BlockAnimTrack then
		BlockAnimTrack:Stop(0.15)
		BlockAnimTrack = nil
	end

	BlockAnimTrack = Animator:LoadAnimation(anim)
	Disconnect(anim)

	BlockAnimTrack.Priority = Enum.AnimationPriority.Action
	BlockAnimTrack:Play(0.1, nil, 1.1)
end


function ClientModule.Unblock()
	--// Notify server of block end
	InputEvent:InvokeServer("Block", { Stage = false })

	--// Stop local block animation
	if BlockAnimTrack then
		BlockAnimTrack:Stop(0.15)
		BlockAnimTrack = nil
	end
end


--// Character lifecycle binding
player.CharacterAdded:Connect(bindCharacter)

if player.Character then
	bindCharacter(player.Character)
end

