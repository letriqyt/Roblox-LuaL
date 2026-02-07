-- Credits to Letriq --

-- Services used throughout the flight controller
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

-- Modules required for shared configuration and logic
local Data = require(ReplicatedStorage.Modules.Data)
local StatInfo = require(ReplicatedStorage.Modules.Configs.StatInfo)
local CoreData = require(ReplicatedStorage.Modules.Tables.Cores)
local FlightModule = require(ReplicatedStorage.Modules.Configs.FlightModule)

-- Remote folder reference
local Remotes = ReplicatedStorage.Remotes

-- Local player references
local player = Players.LocalPlayer
local playerGui = player.PlayerGui

-- Wait until player data is fully initialized
repeat task.wait() until player:GetAttribute("DataLoaded")

-- Hidden values container used for state syncing
local Hidden = player.Hidden

-- Character references
local Character = player.Character or player.CharacterAdded:Wait()
local Humanoid: Humanoid = Character:WaitForChild("Humanoid")
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

-- Physics controllers cloned from script
local BodyVelocity = script.BodyVelocity:Clone()
local BodyGyro = script.BodyGyro:Clone()

-- Camera reference for orientation and effects
local Camera = workspace.CurrentCamera

-- State tracking variables
local LastTrip = 0
local TripActive = false
local WasBoosting = false

-- Cached flight data pulled from module
local FlightData = {}

-- This updates flight values whenever player data changes
local function UpdateFlightData()
	FlightData = FlightModule.GetFlightData()
end

-- Initial pull of flight settings
UpdateFlightData()

-- Refresh flight data when core changes
Hidden.Core.Changed:Connect(UpdateFlightData)

-- Refresh flight data when style changes
Hidden.FlightStyle.Changed:Connect(UpdateFlightData)

-- This checks whether the character is allowed to fly
local function CanFly()
	-- Prevent flight if dead
	if Humanoid.Health <= 0 then
		return false
	end

	-- Prevent flight while ragdolled
	if Character:GetAttribute("Ragdolled") then
		return false
	end

	-- All checks passed
	return true
end

-- This keeps the gyro aligned to the camera
local function UpdateGyro()
	-- Smoothly rotate toward camera orientation
	BodyGyro.CFrame = BodyGyro.CFrame:Lerp(Camera.CFrame, 1)
end

-- This tweens the camera FOV for speed feedback
local function TweenFOV(target, time)
	-- Create tween instance
	local tween = TweenService:Create(
		Camera,
		TweenInfo.new(time, Enum.EasingStyle.Linear),
		{FieldOfView = target}
	)

	-- Play tween
	tween:Play()
end

-- This safely resets all flight forces
local function ResetForces()
	-- Remove velocity force
	BodyVelocity.Velocity = Vector3.zero

	-- Disable velocity force
	BodyVelocity.MaxForce = Vector3.zero

	-- Disable gyro torque
	BodyGyro.MaxTorque = Vector3.zero
end

-- This gathers nearby wind and trip parts
local function GetNearbyEnvironment()
	-- Overlap params for filtering
	local params = OverlapParams.new()

	-- Whitelist for tagged parts
	local whitelist = {}

	-- Collect wind parts
	for _, part in ipairs(CollectionService:GetTagged("WindPart")) do
		table.insert(whitelist, part)
	end

	-- Collect trip parts
	for _, part in ipairs(CollectionService:GetTagged("TripPart")) do
		table.insert(whitelist, part)
	end

	-- Only include tagged parts
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = whitelist

	-- Return overlapping parts
	return workspace:GetPartBoundsInBox(
		HumanoidRootPart.CFrame,
		Vector3.new(5, 5, 5),
		params
	)
end

-- This applies knockback when hitting a trip object
local function ApplyTrip(part)
	-- Enforce cooldown
	if tick() - LastTrip < 3 then
		return
	end

	-- Update last trigger time
	LastTrip = tick()

	-- Mark trip active
	TripActive = true

	-- Determine knockback direction
	local positive = part:GetAttribute("Positive")

	-- Create temporary force
	local knockback = Instance.new("BodyVelocity")

	-- Set knockback direction
	knockback.Velocity =
		(positive and -part.CFrame.LookVector or part.CFrame.LookVector) * 100

	-- Strong force for instant reaction
	knockback.MaxForce = Vector3.new(400000, 400000, 400000)

	-- Name for debugging
	knockback.Name = "TripKnockback"

	-- Parent to root part
	knockback.Parent = HumanoidRootPart

	-- Cleanup after short delay
	Debris:AddItem(knockback, 0.15)
end

-- This calculates movement velocity based on input
local function CalculateVelocity(direction, vector, boosting)
	-- Default speed
	local speed = 0

	-- Boosting speed
	if boosting then
		speed = FlightData.BoostSpeed
		TweenFOV(120, 0.3)

	-- Forward movement speed
	elseif direction ~= "Hover" and vector.Magnitude > 0 then
		speed = FlightData.ForwardSpeed
		TweenFOV(100, 0.3)

	-- Idle flight
	else
		TweenFOV(70, 0.3)
	end

	-- Return final velocity
	return vector * speed
end

-- Main per-frame flight controller
local function FlightController()
	RunService:BindToRenderStep(
		"FlightControl",
		Enum.RenderPriority.Character.Value + 1,
		function(dt)
			-- Stop if flight is not allowed
			if not CanFly() then
				ResetForces()
				return
			end

			-- Enable velocity force
			BodyVelocity.MaxForce = Vector3.new(1e8, 1e8, 1e8)

			-- Enable gyro torque
			BodyGyro.MaxTorque = Vector3.new(4e5, 4e5, 4e5)

			-- Force physics state
			Humanoid:ChangeState(Enum.HumanoidStateType.Physics)

			-- Disable default rotation
			Humanoid.AutoRotate = false

			-- Update orientation
			UpdateGyro()

			-- Get movement direction
			local direction, vector = FlightModule.GetDirection(Humanoid, Camera)

			-- Check boost state
			local boosting =
				Character:GetAttribute("Boosting")
				and Character:GetAttribute("Stamina") > 0
				and direction == "Forward"

			-- Sync direction with server
			if Character:GetAttribute("FlightDirection") ~= direction then
				Remotes.Flight.SetDirection:FireServer(direction)
			end

			-- Play correct animation
			task.spawn(function()
				FlightModule.PlayAnimation(
					boosting and "Boost" or direction,
					Character
				)
			end)

			-- Environmental forces
			local windForce
			local pushForce
			local pushDefect
			local tripPart

			-- Scan nearby parts
			for _, part in ipairs(GetNearbyEnvironment()) do
				if CollectionService:HasTag(part, "WindPart") then
					windForce = part.CFrame.LookVector
					pushForce = part:GetAttribute("PushForce") or 100
					pushDefect = part:GetAttribute("PushDefect") or 0.2
				elseif CollectionService:HasTag(part, "TripPart") then
					tripPart = part
				end
			end

			-- Handle trip collision
			if tripPart and tripPart:GetAttribute("Type") == "Ball" then
				ApplyTrip(tripPart)
				return
			end

			-- Calculate movement velocity
			local velocity = CalculateVelocity(direction, vector, boosting)

			-- Apply wind influence
			if windForce then
				if boosting and pushDefect ~= 0 then
					velocity *= pushDefect
				else
					velocity = windForce * pushForce
				end
			end

			-- Smooth velocity application
			TweenService:Create(
				BodyVelocity,
				TweenInfo.new(0.25, Enum.EasingStyle.Quad),
				{Velocity = velocity}
			):Play()
		end
	)
end

-- Script entry point
local function Main()
	-- Parent physics controllers
	BodyVelocity.Parent = HumanoidRootPart
	BodyGyro.Parent = HumanoidRootPart

	-- Disable conflicting humanoid states
	Humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)
	Humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	Humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	-- Start flight logic
	FlightController()
end

-- Initialize system
Main()

-- Cleanup function on death
local function Cleanup()
	-- Destroy physics objects
	if BodyVelocity then BodyVelocity:Destroy() end
	if BodyGyro then BodyGyro:Destroy() end

	-- Remove render binding
	RunService:UnbindFromRenderStep("FlightControl")
end

-- Handle character death
Humanoid.Died:Connect(function()
	-- Force dead state
	Humanoid:ChangeState(Enum.HumanoidStateType.Dead)

	-- Cleanup resources
	Cleanup()
end)
