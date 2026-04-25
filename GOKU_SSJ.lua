local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Assets = require(ReplicatedStorage.Shared.Constants.Assets)
local TowerMoveType = require(ReplicatedStorage.Shared.Types.TowerDefense.TowerMoveType)
local AnimationUtil = require(ReplicatedStorage.Shared.Util.Character.AnimationUtil)
local VFXUtil = require(ReplicatedStorage.Shared.Util.EmitController)
local EmitModule = require(ReplicatedStorage.Shared.Util.EmitModule)


local VFXPool = {}

local function createPool(asset, size)
	local pool = {}

	for i = 1, size do
		local clone = asset:Clone()
		clone.Parent = workspace.Debris
		clone:PivotTo(CFrame.new(0, -1000, 0)) 
		table.insert(pool, clone)
	end

	return pool
end

local function getFromPool(pool, asset)
	local vfx = table.remove(pool)

	if not vfx then
		vfx = asset:Clone()
	end

	return vfx
end

local function returnToPool(pool, vfx)
	vfx:PivotTo(CFrame.new(0, -1000, 0))
	table.insert(pool, vfx)
end

local Pools = {}

Pools.Punch1Enemy = createPool(Assets.vfx.GokuSSJVFX.KiBarrage.Punch1Enemy, 5)
Pools.Punch2Enemy = createPool(Assets.vfx.GokuSSJVFX.KiBarrage.Punch2Enemy, 5)
Pools.Punch3Enemy = createPool(Assets.vfx.GokuSSJVFX.KiBarrage.Punch3Enemy, 5)
Pools.Top = createPool(Assets.vfx.GokuSSJVFX.KiBarrage.Top, 3)

_G.GokuAOEPools = Pools

local format = require(script.Parent.format)
local tweenService = game:GetService("TweenService")

local function lerp(a, b, c)
	return a + (b - a) * c
end

local function Emit(Skill)
	for i, v in ipairs(Skill:GetDescendants()) do
		warn("RANM?")
		if v:IsA("ParticleEmitter") or v:IsA("Beam") or v:IsA("Trail") then
			warn("RANM232")
			local emitDelay = v:GetAttribute("EmitDelay") or 0
			local emitCount = v:GetAttribute("EmitCount") or 1
			local emitDuration = v:GetAttribute("EmitDuration") or 0
			task.spawn(function()
				task.wait(emitDelay) -- Fixed typo: was "emit DeLay"
				if v:IsA("ParticleEmitter") then
					v:Emit(emitCount)
				end
				if emitDuration > 0 then
					v.Enabled = true
					task.wait(emitDuration)
					v.Enabled = false 
				end
			end)
		end
	end
end

local MOVES: format.Metadata = {
	[TowerMoveType.GOKU_SSJ_LINE] = {
		perform = function(attack, char, enemy)

			local anim = AnimationUtil.loadAnimationToModel(
				char,
				AnimationUtil.getAnimation("GOKU_SSJLine", Assets.animations.GOKU_SSJ)
			)

			anim:Play()
			attack:setAnimation(anim)
			
	

			attack:playVFX(function()

				local rightArm = char:FindFirstChild("Right Arm")
				if not rightArm then return end

				-- KI CHARGE
				local KiChargeVFX = Assets.vfx.GokuSSJVFX.KiCharge.START:Clone()
				KiChargeVFX.Parent = rightArm
				local KiCharge2VFX = Assets.vfx.GokuSSJVFX.KiCharge.Arm_Charge2:Clone()
				KiCharge2VFX.Parent = rightArm

				EmitModule.emit(KiChargeVFX)
				EmitModule.emit(KiCharge2VFX)
				
				local ExplosionCache = {}

				local function preloadExplosion()
					local template = Assets.vfx.GokuSSJVFX.KiExplosion

					for i = 1, 5 do -- small pool
						local clone = template:Clone()
						clone.Parent = workspace.Debris
						clone:PivotTo(CFrame.new(0, -1000, 0)) -- hide underground
						table.insert(ExplosionCache, clone)
					end
				end

				preloadExplosion()


				local connection
				connection = anim:GetMarkerReachedSignal("Start"):Connect(function()

					if connection then
						connection:Disconnect()
					end

					-- KI PROJECTILE
					local kiBlastEffectVFX = Assets.vfx.GokuSSJVFX.KiProjectileEffect:Clone()
					kiBlastEffectVFX.Parent = workspace.Debris
					kiBlastEffectVFX:PivotTo(rightArm.CFrame)

					EmitModule.emit(kiBlastEffectVFX)

					-- ENEMY EXPLOSION
					if enemy and enemy:FindFirstChild("HumanoidRootPart") then
						local onHitVFX = table.remove(ExplosionCache)

						if not onHitVFX then
							onHitVFX = Assets.vfx.GokuSSJVFX.KiExplosion:Clone()
						end

						onHitVFX.Parent = workspace.Debris
						onHitVFX:PivotTo(enemy.HumanoidRootPart.CFrame)

						EmitModule.emit(onHitVFX)

						task.delay(3, function()
							onHitVFX:PivotTo(CFrame.new(0, -1000, 0))
							table.insert(ExplosionCache, onHitVFX)
						end)
					end


					task.delay(3, function()
						if kiBlastEffectVFX then
							kiBlastEffectVFX:Destroy()
						end
					end)
				end)

				anim.Ended:Wait()
			end)
		end,


		assets = {
			animations = { "GOKU_SSJLine" },
			vfx = { "KiBlast" }
		},
	},
	[TowerMoveType.GOKU_SSJ_LINE_BARRAGE] = {
		perform = function(attack, char, enemy)

			local anim = AnimationUtil.loadAnimationToModel(
				char,
				AnimationUtil.getAnimation("GOKU_SSJLine_Barrage", Assets.animations.GOKU_SSJ)
			)

		
	
			anim:Play()
			attack:setAnimation(anim)

			attack:playVFX(function()
				-- Alternating arms
				local hitCount = 0
				local function spawnPunchVFX(armName)
					local arm = char:FindFirstChild(armName)
					if not arm then
						warn("Missing arm:", armName)
						return
					end

					-- Clone the model
					local vfxModel = Assets.vfx.GokuSSJVFX.PunchVFX:Clone()
					vfxModel.Parent = workspace.Debris

					-- Ensure PrimaryPart is set to the visible part
					if not vfxModel.PrimaryPart then
						local punchPart = vfxModel:FindFirstChild("dd") and vfxModel.punch
						if punchPart then
							vfxModel.PrimaryPart = punchPart
						else
							warn("Could not find part 'dd/punch' in PunchVFX model")
							return
						end
					end

					-- Move it in front of the arm
					vfxModel:SetPrimaryPartCFrame(arm.CFrame * CFrame.new(0, 0, -1))

					-- Weld to arm so it follows
					local weld = Instance.new("WeldConstraint")
					weld.Part0 = arm
					weld.Part1 = vfxModel.PrimaryPart
					weld.Parent = vfxModel.PrimaryPart

					-- Emit
					EmitModule.emit(vfxModel)

					-- Clean up
					task.delay(0.6, function()
						if vfxModel then
							vfxModel:Destroy()
						end
					end)
				end



				local function connectHit(markerName)
					anim:GetMarkerReachedSignal(markerName):Connect(function()

						hitCount += 1

						local armName
						if hitCount % 2 == 1 then
							armName = "Right Arm"
						else
							armName = "Left Arm"
						end

						spawnPunchVFX(armName)
					end)
				end


				-- Connect all 5 hits
				connectHit("Hit1")
				connectHit("Hit2")
				connectHit("Hit3")
				connectHit("Hit4")
				connectHit("Hit5")


				-- Wait for animation "Start" marker
				anim:GetMarkerReachedSignal("Start"):Connect(function()
					
					local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
					if torso then
						local topVFX = Assets.vfx.GokuSSJVFX.KiBarrage.Top:Clone()
						topVFX.Parent = workspace.Debris

						-- Pivot it above the torso
						topVFX:PivotTo(torso.CFrame * CFrame.new(0, 0, 0))

						-- Weld it so it follows the torso
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = torso
						weld.Part1 = topVFX
						weld.Parent = topVFX

						EmitModule.emit(topVFX)

						-- Auto cleanup
						task.delay(6, function()
							if topVFX then
								topVFX:Destroy()
							end
						end)
					end


					
					task.delay(0.3, function()
						local connection
						local endTime = tick() + 0.62
						connection = RunService.RenderStepped:Connect(function()
							if tick() >= endTime then
								connection:Disconnect()
								return
							end
							--FX.Slasheshit.CFrame = CFrame.new(char.Torso.CFrame.Position) * CFrame.new(0, -1, 0)
						end)
					end)

					-- Forward motion
					task.delay(0.47, function()
						local forwardTime = 0.8
						local holdTime = 0.5

						local forwardTime = 0.8
						local holdTime = 0.5

						local startCF = char:GetPivot()
						local targetCF = startCF * CFrame.new(0, 0, -7.5)

						local alpha = Instance.new("NumberValue")
						alpha.Value = 0

						local tween = tweenService:Create(
							alpha,
							TweenInfo.new(forwardTime, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
							{Value = 1}
						)

						local connection
						connection = alpha:GetPropertyChangedSignal("Value"):Connect(function()
							char:PivotTo(startCF:Lerp(targetCF, alpha.Value))
						end)

						tween:Play()
						tween.Completed:Wait()

						connection:Disconnect()
						alpha:Destroy()

						task.wait(holdTime)

						-- Snap back cleanly
						char:PivotTo(startCF)
						
					end)

					-- Cleanup FX after 6s
					task.delay(6, function()
						--AfterImage:Destroy()
					end)
				end)
				
				
				anim.Ended:Wait()
			end)

		end,


		assets = {
			animations = { "GOKU_SSJLine_Barrage" },
			vfx = { "PunchVFX" }
		}
	},
	[TowerMoveType.GOKU_SSJ_AOE] = {
		perform = function(attack, char, enemy)
			local anim = AnimationUtil.loadAnimationToModel(
				char,
				AnimationUtil.getAnimation("GOKU_SSJAoe", Assets.animations.GOKU_SSJ)
			)

			-- Store enemy position early
			local enemyLastPosition = nil
			if enemy then
				local enemyHRP = enemy:FindFirstChild("HumanoidRootPart")
				if enemyHRP then
					enemyLastPosition = enemyHRP.Position
				end
			end

			anim.Looped = false
			anim:Play()
			attack:setAnimation(anim)

			local function spawnArmVFX(handName, asset)
				local hand = char:FindFirstChild(handName)
				if not hand then return end

				local vfx = asset:Clone()
				vfx.Parent = hand
				vfx:PivotTo(hand.CFrame * CFrame.new(0, 0, -1))

				local weld = Instance.new("WeldConstraint")
				weld.Part0 = hand
				weld.Part1 = vfx.PrimaryPart
				weld.Parent = vfx.PrimaryPart

				EmitModule.emit(vfx)

				task.delay(1.5, function()
					if vfx then vfx:Destroy() end
				end)
			end

			local function spawnEnemyVFX(asset)
				local spawnPos
				if enemy and enemy:FindFirstChild("HumanoidRootPart") then
					spawnPos = enemy.HumanoidRootPart.Position
				elseif enemyLastPosition then
					spawnPos = enemyLastPosition
				else
					warn("No position available for enemy VFX")
					return
				end

				-- Spawn slightly above the **feet** instead of HRP height
				spawnPos = spawnPos - Vector3.new(0, 3.5, 0)

				local poolName = asset.Name
				local pool = _G.GokuAOEPools[poolName]
				if not pool then
					warn("Pool not found for asset: "..poolName)
					return
				end

				local vfx = getFromPool(pool, asset)
				if not vfx then
					warn("Failed to get VFX from pool: "..poolName)
					return
				end

				if vfx:IsA("Model") and not vfx.PrimaryPart then
					local part = vfx:FindFirstChildWhichIsA("BasePart")
					if part then
						vfx.PrimaryPart = part
					else
						warn("VFX model has no BasePart to pivot!")
						return
					end
				end

				vfx.Parent = workspace.Debris
				local cf = CFrame.new(spawnPos)
				if vfx:IsA("Model") then
					vfx:PivotTo(cf)
				else
					vfx.CFrame = cf
				end

				EmitModule.emit(vfx)

				task.delay(3, function()
					if vfx and vfx.Parent then
						returnToPool(pool, vfx)
					end
				end)
			end

			attack:playVFX(function()
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if not hrp then return end

				anim:GetMarkerReachedSignal("Hit1"):Once(function()
					spawnArmVFX("Right Arm", Assets.vfx.GokuSSJVFX.KiBarrage.Punch1Char)
					spawnEnemyVFX(Assets.vfx.GokuSSJVFX.KiBarrage.Punch1Enemy)
				end)
				anim:GetMarkerReachedSignal("Hit2"):Once(function()
					spawnArmVFX("Left Arm", Assets.vfx.GokuSSJVFX.KiBarrage.Punch2Char)
					spawnEnemyVFX(Assets.vfx.GokuSSJVFX.KiBarrage.Punch2Enemy)
				end)
				anim:GetMarkerReachedSignal("Hit3"):Once(function()
					spawnArmVFX("Right Arm", Assets.vfx.GokuSSJVFX.KiBarrage.Punch3Char)
					spawnEnemyVFX(Assets.vfx.GokuSSJVFX.KiBarrage.Punch3Enemy)
				end)

				anim:GetMarkerReachedSignal("Start"):Connect(function()
					local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
					if torso then
						local pool = _G.GokuAOEPools.Top
						local topVFX = getFromPool(pool, Assets.vfx.GokuSSJVFX.KiBarrage.Top)
						topVFX.Parent = workspace.Debris
						topVFX:PivotTo(torso.CFrame * CFrame.new(0, 0, 0))

						local weld = Instance.new("WeldConstraint")
						weld.Part0 = torso
						weld.Part1 = topVFX
						weld.Parent = topVFX

						EmitModule.emit(topVFX)

						task.delay(6, function()
							if topVFX then topVFX:Destroy() end
						end)
					end

					-- Character jump effect
					task.delay(0.47, function()
						local startFrame = hrp.CFrame
						local peakFrame = startFrame * CFrame.new(0, 7.5, 0)
						local upTween = tweenService:Create(hrp, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {CFrame = peakFrame})
						upTween:Play()
						upTween.Completed:Wait()
						task.wait(0.75)
						local downTween = tweenService:Create(hrp, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {CFrame = startFrame})
						downTween:Play()
					end)
				end)

				anim.Ended:Wait()
			end)
		end,

		assets = {
			animations = { "GOKU_SSJAoe" },
			vfx = { "KiBarrage" }
		}
	},
	
	[TowerMoveType.GOKU_SSJ_LINE_WAVE] = {
		perform = function(attack, char, enemy)
			local anim = AnimationUtil.loadAnimationToModel(
				char,
				AnimationUtil.getAnimation("GOKU_SSJLine_Wave", Assets.animations.GOKU_SSJ)
			)

			anim.Looped = false
			anim:Play()
			attack:setAnimation(anim)

			local hrp = char:FindFirstChild("HumanoidRootPart")
			if not hrp then return end

			local startCFrame = hrp.CFrame

			local function spawnVFX(vfxAsset, parentPart, offset, weldToParent, lookDir)
				local vfx = vfxAsset:Clone()
				vfx.Parent = workspace.Debris

				if vfx:IsA("Model") then
					if not vfx.PrimaryPart then
						local part = vfx:FindFirstChildWhichIsA("BasePart")
						if part then vfx.PrimaryPart = part else warn(vfx.Name.." has no parts!") return end
					end

					local targetCF
					if lookDir then
						targetCF = CFrame.lookAt(parentPart.Position + (offset and offset.Position or Vector3.new()), parentPart.Position + lookDir)
					else
						targetCF = parentPart.CFrame * (offset or CFrame.new())
					end
					vfx:PivotTo(targetCF)

					if weldToParent then
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = parentPart
						weld.Part1 = vfx.PrimaryPart
						weld.Parent = vfx.PrimaryPart
					end

				elseif vfx:IsA("BasePart") then
					local targetCF
					if lookDir then
						targetCF = CFrame.lookAt(parentPart.Position + (offset and offset.Position or Vector3.new()), parentPart.Position + lookDir)
					else
						targetCF = parentPart.CFrame * (offset or CFrame.new())
					end
					vfx.CFrame = targetCF

					if weldToParent then
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = parentPart
						weld.Part1 = vfx
						weld.Parent = vfx
					end
				else
					warn("VFX is neither a Model nor a BasePart: "..vfx.Name)
					return
				end

				EmitModule.emit(vfx)
				task.delay(6, function() if vfx then vfx:Destroy() end end)
			end


			attack:playVFX(function()
				anim:GetMarkerReachedSignal("Charge"):Connect(function()
					spawnVFX(Assets.vfx.GokuSSJVFX.KiKameCharge, hrp, CFrame.new(0,0,0), true)
				end)

				anim:GetMarkerReachedSignal("Charge2"):Connect(function()
					local rightHand = char:FindFirstChild("Right Hand") or char:FindFirstChild("Right Arm")
					if not rightHand then return end
					spawnVFX(Assets.vfx.GokuSSJVFX.KameCharge, rightHand, CFrame.new(0,0,0), true)
				end)

				anim:GetMarkerReachedSignal("Beam"):Connect(function()

					local beamVFX = Assets.vfx.GokuSSJVFX.Kamehameha:Clone()
					beamVFX.Parent = workspace.Debris

					if not beamVFX.PrimaryPart then
						local part = beamVFX:FindFirstChildWhichIsA("BasePart")
						if not part then
							warn("Beam has no parts!")
							return
						end
						beamVFX.PrimaryPart = part
					end

					-- Get beam length
					local beamLength = beamVFX.PrimaryPart.Size.Z

					-- Use HRP CFrame directly (keeps perfect alignment)
					local beamCF =
						hrp.CFrame
						* CFrame.new(0, 0, -(beamLength / 2 + 1)) -- 1 stud in front of character

					beamVFX:PivotTo(beamCF)

					EmitModule.emit(beamVFX)

					task.delay(2, function()
						if beamVFX then
							beamVFX:Destroy()
						end
					end)

				end)


				anim.Ended:Wait()
			end)
		end,

		assets = {
			animations = { "GOKU_SSJLine_Wave" },
			vfx = { "KameCharge", "KiKameCharge", "Kamehameha" }
		}
	}

	
}


return MOVES 
