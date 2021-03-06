repeat wait() until game.Players.LocalPlayer.Character

local Players 	   = game:GetService("Players")
local Player 	   = Players.LocalPlayer
local Character	= Player.Character

   
-- services
local ECS      = require(game.ReplicatedStorage:WaitForChild("ECS"))
local ECSUtil  = require(game.ReplicatedStorage:WaitForChild("ECSUtil"))

-- Components
local Components = game.ReplicatedStorage:WaitForChild("tutorial"):WaitForChild("component")
local WeaponComponent = require(Components:WaitForChild("WeaponComponent"))

-- Systems
local Systems = game.ReplicatedStorage:WaitForChild("tutorial"):WaitForChild("system")
local FiringSystem         = require(Systems:WaitForChild("FiringSystem"))
local PlayerShootingSystem = require(Systems:WaitForChild("PlayerShootingSystem"))
local CleanupFiringSystem  = require(Systems:WaitForChild("CleanupFiringSystem"))

-- Our world
local world = ECS.CreateWorld(nil, { Frequency = 10 })
world.AddSystem(FiringSystem)
world.AddSystem(PlayerShootingSystem)
world.AddSystem(CleanupFiringSystem)
ECSUtil.AddDefaultSystems(world)

-- Our weapon
local rightHand = Character:WaitForChild("RightHand")
local weapon = Instance.new("Part", Character)
weapon.CanCollide = false
weapon.CastShadow = false
weapon.Size       = Vector3.new(0.2, 0.2, 2)
weapon.CFrame     = rightHand.CFrame + Vector3.new(0, 0, -1)
weapon.Color      = Color3.fromRGB(255, 0, 255)

local weldWeapon = Instance.new("WeldConstraint", weapon)
weldWeapon.Part0 = weapon
weldWeapon.Part1 = rightHand

-- weapon bullet spawn
local BulletSpawnPart   = Instance.new("Part", weapon)
BulletSpawnPart.CanCollide = false
BulletSpawnPart.CastShadow = false
BulletSpawnPart.Color      = Color3.fromRGB(255, 255, 0)
BulletSpawnPart.Size       = Vector3.new(0.6, 0.6, 0.6)
BulletSpawnPart.Shape      = Enum.PartType.Ball
BulletSpawnPart.CFrame     = weapon.CFrame + Vector3.new(0, 0, -1)

local weldBulletSpawn = Instance.new("WeldConstraint", BulletSpawnPart)
weldBulletSpawn.Part0 = BulletSpawnPart
weldBulletSpawn.Part1 = weapon

-- Create our entity
local bulletSpawnEntity = ECSUtil.NewBasePartEntity(world, BulletSpawnPart, true, false)

-- Mark as weapon
world.Set(bulletSpawnEntity, WeaponComponent)