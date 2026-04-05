--// Core character references (bound on spawn / respawn)
local character
local humanoid
local animator
local humanoidRootPart
local blockAnimationTrack

--// Roblox services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

--// Combat-related modules
local CombatChecks = require(ReplicatedStorage.Modules.Combat.CombatChecks)
local HitboxModule = require(ReplicatedStorage.Modules.Combat.Hitbox)

--// Helper / movement / visual modules
local SprintModule = require(ReplicatedStorage.Modules.Movement.SprintModule)
local RockModule = require(ReplicatedStorage.Modules.Visuals.RockModule)

--// Networking
local Remotes = ReplicatedStorage.Remotes
local InputEvent = Remotes.Combat.Input
local AnimationEvent = Remotes.Animation.AnimationEvent
local CheckCooldownRemote = Remotes.Other.CheckCooldown

--// Player references
local player = Players.LocalPlayer

--// Animation folders
local animations = ReplicatedFirst.Animations
local combatAnimations = animations.Combat
local fightingStyleAnimations = combatAnimations.FightingStyles
local dashAnimations = combatAnimations.Dashes

--// Dash tuning constants
local DASH_START_SPEED = 60
local DASH_DECAY_RATE = 60
local SIDE_DASH_SPEED = 45
local BACK_DASH_PAUSE = 0.08
local BACK_DASH_BOOST = 1.0
local DASH_TRAIL_SPACING = 2
local DASH_HITBOX_OFFSET = CFrame.new(0, 0, -2.5)
local DASH_HITBOX_SIZE = Vector3.new(4, 5, 5)
local M1_HITBOX_OFFSET = CFrame.new(0, 0, -2.5)
local M1_HITBOX_SIZE = Vector3.new(4, 5, 5)

--// Direction validation tables
local FrontBackDirections = {
	Front = true,
	Back = true,
}

local LeftRightDirections = {
	Left = true,
	Right = true,
}

--// Client state
local isAttacking = false
local isPunching = false
local isDashing = false
local secondFlipUsed = false
local lastTrailPosition

--// Runtime objects
local dashBodyVelocity
local blockReplicationTracks = {}

--// Runtime connections
local connections = {}

--// Client module
local ClientModule = {}

--// Utility to safely disconnect named connections
local function disconnectConnection(name)
	local connection = connections[name]
	if not connection then
		return
	end

	connection:Disconnect()
	connections[name] = nil
end

--// Utility to safely stop and clear named connections
local function clearConnectionGroup(...)
	for _, name in ipairs({ ... }) do
		disconnectConnection(name)
	end
end

--// Fetch animator from any character instance
local function getAnimatorFromCharacter(targetCharacter)
	local targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid then
		return nil
	end

	return targetHumanoid:FindFirstChildOfClass("Animator")
end

--// Check shift-lock camera state
local function isShiftLocked()
	return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end

--// Resolve current fighting style animation folder
local function getCurrentStyleFolder()
	if not character then
		return nil
	end

	local styleName = character:GetAttribute("FightingStyle")
	if not styleName then
		return nil
	end

	return fightingStyleAnimations:FindFirstChild(styleName)
end

--// Create a standard combat hitbox
local function createCombatHitbox(rootPart, offset, size, actionName)
	HitboxModule.CreateHitbox(rootPart, offset, size, 0.15, false, nil, function(enemies)
		if enemies and #enemies > 0 then
			InputEvent:InvokeServer(actionName, {
				Enemy = enemies,
				Stage = "Hit",
			})
		end
	end)
end

--// Stop trail emission and cleanup
local function stopDashTrail()
	disconnectConnection("DashTrail")
	lastTrailPosition = nil
end

--// Spawn rock trail during dash movement
local function trySpawnDashTrail()
	if not isDashing or not dashBodyVelocity or not humanoidRootPart then
		return
	end

	if dashBodyVelocity.Velocity.Magnitude < 1 then
		return
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	rayParams.FilterDescendantsInstances = { character }

	local rayResult = workspace:Raycast(humanoidRootPart.Position, Vector3.new(0, -12, 0), rayParams)
	if not rayResult then
		return
	end

	local groundPosition = rayResult.Position - Vector3.new(0, 0.15, 0)
	if lastTrailPosition and (groundPosition - lastTrailPosition).Magnitude < DASH_TRAIL_SPACING then
		return
	end

	lastTrailPosition = groundPosition

	local direction = dashBodyVelocity.Velocity.Unit
	local trailCFrame = CFrame.lookAt(groundPosition, groundPosition + direction)

	RockModule.Trail(trailCFrame, DASH_TRAIL_SPACING, 1, 2, 0.35, false, {
		Material = rayResult.Instance.Material,
		Color = rayResult.Instance.Color,
	})
end

--// Determine finisher based on jump / fall state
local function getComboFinisher()
	if not humanoid then
		return nil
	end

	local isJumpHeld = humanoid.Jump
	local isMouseHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
	local isFalling = humanoid:GetState() == Enum.HumanoidStateType.Freefall

	if isJumpHeld and isMouseHeld and not isFalling then
		return "Uppercut"
	end

	if isFalling then
		return "Downslam"
	end

	return nil
end

--// Convert yaw to forward vector
local function forwardFromYaw(yaw)
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

--// Resolve dash direction from camera / character state
local function getDashDirection(direction, allowCameraSteer)
	local camera = workspace.CurrentCamera
	if not camera or not humanoidRootPart then
		return nil
	end

	if allowCameraSteer then
		local lookVector = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		local rightVector = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)

		if lookVector.Magnitude == 0 or rightVector.Magnitude == 0 then
			return nil
		end

		lookVector = lookVector.Unit
		rightVector = rightVector.Unit

		if direction == "Front" then
			return lookVector
		elseif direction == "Back" then
			return -lookVector
		elseif direction == "Right" then
			return rightVector
		elseif direction == "Left" then
			return -rightVector
		end
	end

	local lookVector = humanoidRootPart.CFrame.LookVector
	local flattenedLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flattenedLook.Magnitude == 0 then
		return nil
	end

	return flattenedLook.Unit
end

--// Full dash cleanup
local function cancelDash(state)
	if state.cancelling then
		return
	end

	state.cancelling = true

	if not isDashing then
		return
	end

	isDashing = false
	secondFlipUsed = false

	clearConnectionGroup("DashLoop", "DashHealth", "DashTrail")

	if dashBodyVelocity then
		dashBodyVelocity:Destroy()
		dashBodyVelocity = nil
	end

	if state.animationTrack and state.animationTrack.IsPlaying then
		state.animationTrack:Stop(0.1)
	end

	if humanoid then
		humanoid.AutoRotate = state.originalAutoRotate
	end

	lastTrailPosition = nil
end

--// Animation replication handler (Block)
local function handleBlockReplication(data)
	local targetCharacter = data and data.Character
	local shouldBlock = data and data.State
	if not targetCharacter then
		return
	end

	local targetAnimator = getAnimatorFromCharacter(targetCharacter)
	if not targetAnimator then
		return
	end

	local styleName = targetCharacter:GetAttribute("FightingStyle")
	if not styleName then
		return
	end

	local styleFolder = fightingStyleAnimations:FindFirstChild(styleName)
	local blockAnimation = styleFolder and styleFolder:FindFirstChild("Block")
	if not blockAnimation then
		return
	end

	if shouldBlock then
		if blockReplicationTracks[targetCharacter] then
			return
		end

		local track = targetAnimator:LoadAnimation(blockAnimation)
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = true
		track:Play()
		blockReplicationTracks[targetCharacter] = track
		return
	end

	local existingTrack = blockReplicationTracks[targetCharacter]
	if existingTrack then
		existingTrack:Stop(0.15)
		existingTrack:Destroy()
		blockReplicationTracks[targetCharacter] = nil
	end
end

--// Central animation dispatcher
AnimationEvent.OnClientEvent:Connect(function(action, data)
	if action == "Block" then
		handleBlockReplication(data)
	else
		warn("No animation handler for:", action)
	end
end)

--// Rebind all character-dependent references on respawn
local function bindCharacter(newCharacter)
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid")
	animator = humanoid:WaitForChild("Animator")
	humanoidRootPart = newCharacter:WaitForChild("HumanoidRootPart")

	isAttacking = false
	isPunching = false
	isDashing = false
	secondFlipUsed = false
	lastTrailPosition = nil
	blockAnimationTrack = nil

	if dashBodyVelocity then
		dashBodyVelocity:Destroy()
		dashBodyVelocity = nil
	end

	clearConnectionGroup("M1", "DashLoop", "DashHealth", "DashTrail")
end

--// Play a combo animation and attach the hit marker callback
local function playComboAnimation(animationObject, actionName, playbackSpeed, onComplete)
	local track = animator:LoadAnimation(animationObject)
	track:Play(nil, nil, playbackSpeed)

	InputEvent:InvokeServer(actionName, {
		Enemy = nil,
		Stage = "Start",
	})

	disconnectConnection("M1")
	connections.M1 = track:GetMarkerReachedSignal("Hit"):Connect(function()
		createCombatHitbox(humanoidRootPart, M1_HITBOX_OFFSET, M1_HITBOX_SIZE, actionName)
	end)

	track.Stopped:Connect(function()
		isAttacking = false
		if onComplete then
			onComplete()
		end
	end)
end

--// Primary melee attack (M1 / combo system)
function ClientModule.M1()
	if not CombatChecks.CanM1(character) then
		return
	end

	if isAttacking then
		return
	end

	local combo = character:GetAttribute("Combo") or 1
	local styleFolder = getCurrentStyleFolder()
	if not styleFolder then
		return
	end

	isAttacking = true

	--// Combo finisher handling
	if combo == 4 then
		local finisherName = getComboFinisher()
		if finisherName then
			local finisherAnimation = styleFolder:FindFirstChild(finisherName)
			if not finisherAnimation then
				isAttacking = false
				return
			end

			local finisherTrack = animator:LoadAnimation(finisherAnimation)
			finisherTrack:Play(nil, nil, 1.1)

			InputEvent:InvokeServer(finisherName, {
				Stage = "Start",
			})

			disconnectConnection(finisherName)
			connections[finisherName] = finisherTrack:GetMarkerReachedSignal("Hit"):Connect(function()
				createCombatHitbox(humanoidRootPart, M1_HITBOX_OFFSET, M1_HITBOX_SIZE, finisherName)
			end)

			SprintModule.SuppressSprint(true)
			finisherTrack.Stopped:Connect(function()
				isAttacking = false
			end)
			return
		end
	end

	--// Standard combo attack
	local comboAnimation = styleFolder:FindFirstChild(combo)
	if not comboAnimation then
		isAttacking = false
		return
	end

	playComboAnimation(comboAnimation, "M1", 1)
end

--// Dash handler
function ClientModule.Dash(direction)
	local isFrontBack = FrontBackDirections[direction] == true
	local isLeftRight = LeftRightDirections[direction] == true
	local isValidDirection = isFrontBack or isLeftRight

	if not isValidDirection then
		return
	end

	if not CombatChecks.CanDash(character) then
		return
	end

	if isAttacking and isFrontBack then
		return
	end

	if isDashing then
		return
	end

	local cooldownKey = isFrontBack and "Forward" or "Side"
	local onCooldown = CheckCooldownRemote:InvokeServer(character.Name, cooldownKey)
	if onCooldown then
		return
	end

	if not humanoid or not animator or not humanoidRootPart then
		return
	end

	local dashAnimation = dashAnimations:FindFirstChild(direction)
	local frontHitAnimation = dashAnimations:FindFirstChild("FrontHit")
	if not dashAnimation or not frontHitAnimation then
		return
	end

	local dashStats = {
		Front = {
			Speed = DASH_START_SPEED,
			CameraSteer = false,
		},
		Back = {
			Speed = DASH_START_SPEED,
			CameraSteer = true,
		},
		Left = {
			Speed = SIDE_DASH_SPEED,
			CameraSteer = true,
		},
		Right = {
			Speed = SIDE_DASH_SPEED,
			CameraSteer = true,
		},
	}

	local stats = dashStats[direction]
	if not stats then
		return
	end

	--// Enter dash state
	isDashing = true
	secondFlipUsed = false
	lastTrailPosition = nil

	local dashState = {
		cancelling = false,
		originalAutoRotate = humanoid.AutoRotate,
		lockedYaw = nil,
		animationTrack = nil,
	}

	--// Rotation locking for forward dash
	if direction == "Front" then
		humanoid.AutoRotate = false
		local _, yaw = humanoidRootPart.CFrame:ToEulerAnglesYXZ()
		dashState.lockedYaw = yaw
	end

	--// Play dash animation
	local animationTrack = animator:LoadAnimation(dashAnimation)
	animationTrack.Priority = Enum.AnimationPriority.Action
	animationTrack:Play(0.05, nil, 1.1)
	dashState.animationTrack = animationTrack

	--// Notify server of dash start
	InputEvent:InvokeServer("Dash", {
		Stage = "Start",
		Direction = direction,
	})

	--// Initial dash direction resolution
	local dashDirection = getDashDirection(direction, stats.CameraSteer)
	if not dashDirection then
		cancelDash(dashState)
		return
	end

	--// Initialize dash velocity
	dashBodyVelocity = Instance.new("BodyVelocity")
	dashBodyVelocity.MaxForce = Vector3.new(50000, 0, 50000)
	dashBodyVelocity.Velocity = dashDirection * stats.Speed
	dashBodyVelocity.Parent = humanoidRootPart

	local currentSpeed = stats.Speed
	local startingHealth = humanoid.Health

	--// Cancel dash on damage
	connections.DashHealth = humanoid.HealthChanged:Connect(function(newHealth)
		if newHealth < startingHealth then
			cancelDash(dashState)
		end
	end)

	--// Dash movement loop
	connections.DashLoop = RunService.RenderStepped:Connect(function(deltaTime)
		if not isDashing or not dashBodyVelocity then
			return
		end

		--// Forward dash yaw locking
		if direction == "Front" and dashState.lockedYaw then
			local currentPosition = humanoidRootPart.Position

			if isShiftLocked() then
				local cameraLook = workspace.CurrentCamera.CFrame.LookVector
				dashState.lockedYaw = math.atan2(-cameraLook.X, -cameraLook.Z)
				dashDirection = forwardFromYaw(dashState.lockedYaw)
			end

			humanoidRootPart.CFrame = CFrame.new(currentPosition) * CFrame.fromOrientation(0, dashState.lockedYaw, 0)
		end

		--// Live camera steering
		if stats.CameraSteer then
			local updatedDirection = getDashDirection(direction, true)
			if updatedDirection then
				dashDirection = updatedDirection
			end
		end

		if dashDirection.Magnitude == 0 then
			cancelDash(dashState)
			return
		end

		dashDirection = Vector3.new(dashDirection.X, 0, dashDirection.Z).Unit
		dashBodyVelocity.Velocity = dashDirection * currentSpeed

		currentSpeed -= DASH_DECAY_RATE * deltaTime
		if currentSpeed <= 0 then
			cancelDash(dashState)
			return
		end

		trySpawnDashTrail()
	end)

	--// Dash impact window
	animationTrack:GetMarkerReachedSignal("End"):Connect(function()
		if not isDashing then
			return
		end

		local hitTrack = animator:LoadAnimation(frontHitAnimation)
		hitTrack.Priority = Enum.AnimationPriority.Action
		hitTrack:Play(0.05, nil, 1.1)

		InputEvent:InvokeServer("Dash", {
			Stage = "HitPoint",
			Direction = direction,
		})

		createCombatHitbox(humanoidRootPart, DASH_HITBOX_OFFSET, DASH_HITBOX_SIZE, "Dash")
	end)

	--// Back dash flip logic
	animationTrack:GetMarkerReachedSignal("Back"):Connect(function()
		if not isDashing then
			return
		end

		if direction ~= "Back" or secondFlipUsed then
			return
		end

		secondFlipUsed = true

		if dashBodyVelocity then
			dashBodyVelocity.Velocity = Vector3.zero
		end

		stopDashTrail()

		task.delay(BACK_DASH_PAUSE, function()
			if not isDashing then
				return
			end

			local updatedDirection = getDashDirection(direction, true)
			if not updatedDirection then
				cancelDash(dashState)
				return
			end

			dashDirection = Vector3.new(updatedDirection.X, 0, updatedDirection.Z).Unit
			currentSpeed = DASH_START_SPEED * BACK_DASH_BOOST

			if dashBodyVelocity then
				dashBodyVelocity.Velocity = dashDirection * currentSpeed
			end

			trySpawnDashTrail()
		end)
	end)

	--// Final cleanup on animation stop
	animationTrack.Stopped:Connect(function()
		cancelDash(dashState)
	end)
end

--// Block handler
function ClientModule.Block()
	--// Notify server of block start
	InputEvent:InvokeServer("Block", {
		Stage = true,
	})

	--// Resolve block animation from fighting style
	local styleFolder = getCurrentStyleFolder()
	if not styleFolder then
		return
	end

	local blockAnimation = styleFolder:FindFirstChild("Block")
	if not blockAnimation then
		return
	end

	--// Replace existing block animation if needed
	if blockAnimationTrack then
		blockAnimationTrack:Stop(0.15)
		blockAnimationTrack = nil
	end

	blockAnimationTrack = animator:LoadAnimation(blockAnimation)
	blockAnimationTrack.Priority = Enum.AnimationPriority.Action
	blockAnimationTrack.Looped = true
	blockAnimationTrack:Play(0.1, nil, 1.1)
end

--// Unblock handler
function ClientModule.Unblock()
	--// Notify server of block end
	InputEvent:InvokeServer("Block", {
		Stage = false,
	})

	--// Stop local block animation
	if blockAnimationTrack then
		blockAnimationTrack:Stop(0.15)
		blockAnimationTrack = nil
	end
end

--// Auto-repeat M1 while holding punch input

task.spawn(function()
	while task.wait() do
		if isPunching then
			ClientModule.M1()
		end
	end
end)

--// Character lifecycle binding
player.CharacterAdded:Connect(bindCharacter)

if player.Character then
	bindCharacter(player.Character)
end

return ClientModule

