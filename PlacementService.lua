local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local MapService = require(script.Parent.MapService)
local TowerService = require(script.Parent.TowerService)
local Configs = require(ReplicatedStorage.Shared.Constants.Configs)
local Towers = require(ReplicatedStorage.Shared.Constants.Towers)
local Events = require(ReplicatedStorage.Shared.Events)
local Network = require(ReplicatedStorage.Shared.Network)
local Tower = require(ReplicatedStorage.Shared.Objects.Tower)
local EntityService = require(ReplicatedStorage.Shared.Services.Global.EntityService)
local PlayerService = require(ReplicatedStorage.Shared.Services.Global.PlayerService)
local selectors = require(ReplicatedStorage.Shared.Store.selectors)
local ReflexUtil = require(ReplicatedStorage.Shared.Util.Global.ReflexUtil)
local TowerUtil = require(ReplicatedStorage.Shared.Util.Global.TowerUtil)
local Store = ReflexUtil.useStore()
local MatchService = require(ReplicatedStorage.Shared.Services.TowerDefense.MatchService)
local GamemodeType = require(ReplicatedStorage.Shared.Types.TowerDefense.GamemodeType)
local CargoService = require(ReplicatedStorage.Shared.Services.TowerDefense.CargoService)

local function inRegion3(region: Region3, point: Vector3)
    local relative = (point - region.CFrame.Position) / region.Size
    return -0.5 <= relative.X and relative.X <= 0.5
       and -0.5 <= relative.Y and relative.Y <= 0.5
       and -0.5 <= relative.Z and relative.Z <= 0.5
end

local PlacementService = {}
PlacementService._raycastParams = RaycastParams.new()
PlacementService._raycastParams.FilterType = Enum.RaycastFilterType.Include

function PlacementService:OnInit()
	Events.TowerDefenseMapChanged:Connect(function(event)
		if event.model:FindFirstChild("MapEffects") then
			event.model.MapEffects.Parent = workspace.Debris
		end
		
		PlacementService._raycastParams:AddToFilter(event.model)
	end)

	if RunService:IsServer() then
		local CashService = require(ServerScriptService.Server.Services.TowerDefense.CashService)

		Network.towerDefense.place_tower:Server():On(function(plr, info)
			local state = Store:getState()

			local component = PlayerService.getPlayerByUser(plr.UserId)
			if not component then
				return
			end
			
			local equipped = selectors.selectPlayerTowersEquipped(tostring(plr.UserId))(state)
			local data = equipped and table.find(equipped, info.uid) and selectors.selectPlayerTower(tostring(plr.UserId), info.uid)(state)

			if not data then
				return
			end

			local props: Tower.Props = {
				position = info.position,
				rotation = info.rotation,
				owner = plr.UserId,
				data = data,
				uid = (nil :: any)
			}

			local tower = Tower.new(props, nil, EntityService.calculateStats(TowerUtil.toPsuedoEntity(data), TowerUtil.useStats(data.id)))
			local canPlace = PlacementService.check(tower) == true

			tower:destroy()

			if not canPlace then
				return
			end
			
			TowerService.spawnTower(props,nil,plr)
			CashService.increment(component, -tower.stats.cost)
		end)
	end
end

function PlacementService.maxOfTowerPlaced(placing: Tower.Self)
	local state = Store:getState()
	local data = state.data.tower[tostring(placing.props.owner)]
	local towers = 0
	local uniqueFound = false

	if data then
		for _,v in data.equipped do
			local data = data.inventory[v]
			if data and data.id == placing.props.data.id then
				if table.find(data.traits, "liege") or table.find(data.traits, "exclusive") then
					uniqueFound = true
					break
				end
			end
		end
	end

	for i,v in TowerService.getAll() do
		if v.props.owner == placing.props.owner and v.props.data.id == placing.props.data.id then
			towers += 1
		end
	end

	return towers >= if uniqueFound then 1 else Towers[placing.props.data.id].placement.max, uniqueFound
end
function PlacementService.hasMaxPlaced(user: number)
	local towers = 0
	for i,v in TowerService.getAll() do
		if v.props.owner == user then
			towers += 1
		end
	end
	return towers >= Configs.TOWER_MAX_PLACEMENT
end

function PlacementService.raycast(position: Vector3, id: string): {Raycast: RaycastResult?; ValidPlacement: boolean,ValidSiege : boolean}?
	local model = MapService.getModel()
	local mapPos = model:GetPivot().Position
	local size = model:GetExtentsSize()
	local region = Region3.new(mapPos - (size), mapPos + (size))

	local raycast = workspace:Raycast(
		position+Vector3.yAxis*5, 
		Vector3.yAxis*-10,
		PlacementService._raycastParams
	)
	local SiegeRange = Configs.CARGO_RANGE/2

	if raycast then
		--if not inRegion3(region, raycast.Position) then
	--	return {ValidPlacement = false}
		--end
		local ValidSiege = true

		if MatchService.getData().gamemode == GamemodeType.SIEGE then
			ValidSiege = false
			for i,Cargo in pairs(CargoService.getAll()) do
				if Cargo.position then
					if (Cargo.position - position).Magnitude <= SiegeRange then
						ValidSiege = true
					end
				end
			end
		end

		local metadata = Towers[id].placement
		return {
			Raycast = raycast,
			ValidPlacement = if metadata.type == "ground" then raycast.Instance:HasTag("Ground")
				elseif metadata.type == "hill" then raycast.Instance:HasTag("Hill")
				else raycast.Instance:HasTag("Ground") or raycast.Instance:HasTag("Hill"),
			ValidSiege = ValidSiege,
		}
	end
end

function PlacementService.isOverlapping(position: Vector3)
	local inRange = TowerService.getInRange(position, 3.2)
	table.sort(inRange, function(a,b)
		return (a.props.position - position).Magnitude < (b.props.position - position).Magnitude
	end)
	return inRange[1] and ((inRange[1].props.position - position).Magnitude < 3.2)
end

function PlacementService.check(placing: Tower.Self): (string | boolean, string?)
	
	local metadata = Towers[placing.props.data.id]
	local plr = PlayerService.getPlayerByUser(tonumber(placing.props.owner) :: number)

	local raycastResult = PlacementService.raycast(placing.props.position, placing.props.data.id)
	local canPlace = raycastResult and raycastResult.ValidPlacement 
		and not PlacementService.isOverlapping(placing.props.position)
	
	local SiegeCheck = raycastResult.ValidSiege


	if PlacementService.hasMaxPlaced(placing.props.owner) then
		return `Placement limit reached!`, "error"
	elseif PlacementService.maxOfTowerPlaced(placing) then
		return `Placement Limit Reached!`, "error"
	elseif canPlace ~= true then
		return "Can't place here", "error"
	elseif SiegeCheck ~= true then
		return "Must place within Cargo range!", "error"
	elseif (plr and plr.cash) < metadata.stats[1].cost then
		return `Not enough cash (${metadata.stats[1].cost})`, "error"
	end

	return true
end

function PlacementService.getRaycastParams()
	return PlacementService._raycastParams
end

return PlacementService
