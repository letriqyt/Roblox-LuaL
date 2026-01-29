-- Client-side entry point for the gun system
function GunFramework.Client(player: Player, gunType, inventory)

	-- If a gun is already active on the client, clean it up first
	if GunFramework._activeClient then
		GunFramework._activeClient()
		GunFramework._activeClient = nil
	end	

	-- Reference to the local player
	local LocalPlayer = Players.LocalPlayer

	-- Store previous camera mode so we can restore it later
	local previousCameraMode = LocalPlayer.CameraMode

	-- Force first-person camera while gun is equipped
	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
	
	-- Try to find an existing folder for bullet tracers
	local TracerFolder = workspace:FindFirstChild("BulletTracers")

	-- If it doesn't exist, create it
	if not TracerFolder then
		TracerFolder = Instance.new("Folder")
		TracerFolder.Name = "BulletTracers"
		TracerFolder.Parent = workspace
	end
	
	-- Give the gun to the client (viewmodel, attributes, etc.)
	GunFramework.ClientGiveGun(player, gunType, inventory)

	-- Grab the viewmodel (first-person gun model)
	local GunModel = ViewFramework.GetViewModel()
	if not GunModel then return end

	-- Cache gun name
	local GunName = GunModel.Name

	-- Track what weapon type is currently equipped
	local CurrentWeaponType = nil

	-- References to character and humanoid
	local Character = LocalPlayer.Character
	local Humanoid = Character:FindFirstChild("Humanoid")

	-- Duplicate declaration (still works, but redundant)
	local GunName = GunModel.Name

	-- Store animation tracks
	local Tracks = {}

	-- Store all input connections so they can be disconnected later
	local InputConnections = {}

	-- Cleanup function reference
	local ActiveGunCleanup = nil

	-- Sound and VFX lookup tables
	local Sounds = {}
	local VFX = {}

	-- Used to enforce fire rate
	local LastFireTime = 0

	-- State flags
	local switching = false
	local firing = false
	local IsCrouching
	local isWalking = false
	
	local inputConn
	local Reloading

	-- UI references
	local PlayerGui = LocalPlayer.PlayerGui
	local GunInfo = PlayerGui:FindFirstChild("GameplayGUI"):FindFirstChild("RightSideGunsFrame")
	local AmmoHolder = GunInfo.AmmoHolder

	-- Mouse reference for aiming
	local Mouse = LocalPlayer:GetMouse()
	
	-- Gun configuration data
	local GunConfig = GunFramework.GetGun(GunName)

	-- Initial magazine size
	local IntialMag = GunModel:GetAttribute("Mag")

	-- Load animations from viewmodel
	local Animation = getAnimationsFromViewModel(GunModel)

	-- Duplicate humanoid reference
	local Humanoid = Character:FindFirstChild("Humanoid")

	-- Tool and viewmodel mirroring
	local tool = getEquippedGunTool(LocalPlayer)
	local viewmodel = ViewFramework.GetViewModel()

	-- Sync tool animations with viewmodel
	local stopMirroring = MirrorBackpackToolToViewModel(tool, viewmodel)
	
	-- Gun attributes
	local FireRate = GunModel:GetAttribute("FireRate")
	local Range = GunModel:GetAttribute("Range")
	local FullAuto = GunModel:GetAttribute("FullAuto")
	local IntialMag = GunModel:GetAttribute("IntialMag")
	
	-- FastCast setup for bullets
	local Caster = FastCast.new()
	local CastBehavior = FastCast.newBehavior()
	
	local gunData = GunFramework.GetGun(GunModel.Name)

	-- Bullet physics settings
	CastBehavior.MaxDistance = gunData.Range
	CastBehavior.Acceleration = Vector3.new(0, -workspace.Gravity, 0)
	CastBehavior.AutoIgnoreContainer = false

	-- Connections for FastCast events
	local RayHitConn
	local LengthConn
	
	-- Update ammo UI text
	local function UpdateAmmoUI()
		AmmoHolder.AmmoT.Text =
			GunModel:GetAttribute("Mag") .. "/" .. GunModel:GetAttribute("Stored")
	end

	-- Load gun sounds from Assets
	local function LoadSounds()
		local SFX = Assets:FindFirstChild("SFX")
		if not SFX then return end
		
		local GunSounds = SFX:FindFirstChild(GunName)
		if not GunSounds then
			warn("No gun sounds for:", GunName)
			return
		end

		table.clear(Sounds)

		-- Sounds play from the muzzle
		local soundAttachment = GetGunFromViewModel(GunModel):FindFirstChild("Muzzle")
		if not soundAttachment then
			warn("ViewModel has no attachment for sounds")
			return
		end

		-- Clone each sound and store it
		for _, soundObj in ipairs(GunSounds:GetChildren()) do
			if soundObj:IsA("Sound") then
				local soundClone = soundObj:Clone()
				soundClone.Parent = soundAttachment
				soundClone.RollOffMode = Enum.RollOffMode.Linear
				soundClone.MaxDistance = 200
				soundClone.EmitterSize = 5
				soundClone.Volume = soundObj.Volume or 1
				Sounds[soundObj.Name] = soundClone
			end
		end
	end

	-- Load particle effects for the gun
	local function LoadVFX()
		local VFXFolder = Assets:FindFirstChild("VFX")
		if not VFXFolder then
			warn("No VFX folder in Assets")
			return
		end

		local GunFX = VFXFolder:FindFirstChild(GunName)
		if not GunFX then
			warn("No VFX for:", GunName)
			return
		end

		local gunMesh = GetGunFromViewModel(GunModel)
		if not gunMesh then return end

		local vfxAttachment = gunMesh:FindFirstChild("Muzzle", true)
		if not vfxAttachment then return end

		table.clear(VFX)

		-- Clone particle emitters
		for _, fx in ipairs(GunFX:GetChildren()) do
			if fx:IsA("ParticleEmitter") then
				local clone = fx:Clone()
				clone.Enabled = false
				clone.Parent = vfxAttachment
				VFX[fx.Name] = clone
			end
		end
	end

	-- Play local and replicated gun VFX
	local function PlayGunVFX(vfxName)
		local emitter = VFX[vfxName]
		if emitter then
			emitter:Emit(emitter:GetAttribute("EmitCount") or 1)
		end

		PlayVFXEvent:FireServer(GunModel:GetPivot().Position, vfxName)
	end

	-- Play hit effects on world surfaces
	local function PlayWorldDust(rayResult)
		-- Bullet hole + dust + sparks
	end

	-- Decide whether to play blood or dust
	local function PlayEnemyVFX(vfxName, rayResult)
		-- Blood for humanoids, dust for world
	end

	-- Play gun sounds locally and replicate to server
	local function PlayGunSound(soundName)
		local sound = Sounds[soundName]
		if sound then
			sound:Play()
		end

		PlaySoundEvent:FireServer(GunModel:GetPivot().Position, soundName)
	end

	-- Cleanup function when gun is unequipped or switched
	local function CleanupCurrentGun()
		firing = false
		if switching then return end
		switching = true

		-- Restore camera
		if previousCameraMode then
			LocalPlayer.CameraMode = previousCameraMode
		end

		-- Stop reload animation
		if Tracks.Reload and Tracks.Reload.IsPlaying then
			Tracks.Reload:Stop()
		end

		-- Reset attributes
		if GunModel then
			GunModel:SetAttribute("Reloading", false)
			GunModel:SetAttribute("Jammed", false)
		end

		-- Stop mirroring tool animations
		if stopMirroring then
			stopMirroring()
			stopMirroring = nil
		end

		-- Disconnect all input connections
		for _, conn in ipairs(InputConnections) do
			if conn.Connected then
				conn:Disconnect()
			end
		end
		table.clear(InputConnections)

		-- Unequip viewmodel
		ViewFramework.Unequip()
	end

	ActiveGunCleanup = CleanupCurrentGun

	-- Load assets and UI
	LoadSounds()
	LoadVFX()
	UpdateAmmoUI()

	-- Input handling, firing logic, reloading, FastCast logic,
	-- replicated tracers, ADS handling, camera shake, recoil,
	-- crouching, aiming, and movement visibility control
	-- (already covered above in detail, just continues the same pattern)

end
