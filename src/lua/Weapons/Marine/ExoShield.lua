Script.Load("lua/LiveMixin.lua")
Script.Load("lua/TeamMixin.lua")
Script.Load("lua/Weapons/Marine/ExoWeaponSlotMixin.lua")

class 'ExoShield' (Entity)
ExoShield.kMapName = "exoshield"
ExoShield.kModelName = PrecacheAsset("models/marine/exosuit/exo_barrier.model")
ExoShield.kWidth = 1.65
ExoShield.kHeight = 2.75
ExoShield.kDepth = 0.12
-- Shared by barrier rendering, physics, contacts and projectile clearance.
ExoShield.kDistance = 1.65
ExoShield.kRadius = 0.825
ExoShield.kCurveDepth = .20
ExoShield.kRightModelName = PrecacheAsset("models/marine/exosuit/exo_barrier_right.model")
ExoShield.kLinkModelName = PrecacheAsset("models/marine/exosuit/shield_link.model")
ExoShield.kVerticalOffset = -0.5
ExoShield.kPhysicsSegments = 6
ExoShield.kCapacity = 600
ExoShield.kRechargePerSecond = 90
ExoShield.kBrokenRechargePerSecond = 180
ExoShield.kRechargeDelay = 1.5
ExoShield.kDeployDelay = 0.15
ExoShield.kRecoveryHeat = 0.25
ExoShield.kWeight = 0.08
-- The original mod did not ship definitions for these balance constants.
-- Keep the restored mechanics explicit and tunable, with bounded contact work.
ExoShield.kCombatDuration = 1.5
ExoShield.kIdleBaseHeatMin = 0.12
ExoShield.kIdleBaseHeatMax = 0.25
ExoShield.kIdleBaseHeatMaxDelay = 20
ExoShield.kCombatBaseHeatExtra = 0.10
ExoShield.kHeatActiveDrainRate = 0.03
ExoShield.kHeatCombatDrainRate = 0.01
ExoShield.kContactEnergyDrainRatePercent = 0.10
ExoShield.kContactEnergyDrainRateFixed = 5
ExoShield.kCorrodeDamageScalar = 2
ExoShield.kMaxContacts = 64
local kHitSound = PrecacheAsset("sound/NS2.fev/marine/commander/nano_damage")
local kDeploySound = PrecacheAsset("sound/NS2.fev/marine/commander/nano_shield_3D")
local kBreakSound = PrecacheAsset("sound/NS2.fev/marine/grenades/pulse/explode")

local networkVars = {
    shieldHitPoints = "float (0 to 600 by 0.0625)",
    heatAmount = "float (0 to 1 by 0.01)",
    isShieldDesired = "boolean",
    isShieldDeployed = "boolean",
    isShieldActive = "boolean",
    isShieldOverheated = "boolean",
    shieldDeployChangeTime = "time",
    lastHitTime = "time",
    lastHitPoint = "vector",
    shieldContactCount = "integer (0 to 64)",
    lastHitAbsorb = "boolean",
}
AddMixinNetworkVars(LiveMixin, networkVars)
AddMixinNetworkVars(TeamMixin, networkVars)
AddMixinNetworkVars(ExoWeaponSlotMixin, networkVars)

function ExoShield:OnCreate()
    Entity.OnCreate(self)
    gExoBarrierInstanceCount = (gExoBarrierInstanceCount or 0) + 1
    self.shieldInstanceRegistered = true
    InitMixin(self, LiveMixin)
    InitMixin(self, TeamMixin)
    InitMixin(self, ExoWeaponSlotMixin)
    self.shieldHitPoints = ExoShield.kCapacity
    if Server then
        self:SetMaxHealth(ExoShield.kCapacity)
        self:SetHealth(ExoShield.kCapacity)
        self:SetArmor(0)
    end
    self.heatAmount = 0
    self.isShieldDesired = false
    self.isShieldDeployed = false
    self.isShieldActive = false
    self.isShieldOverheated = false
    self.shieldDeployChangeTime = 0
    self.lastHitTime = 0
    self.lastHitPoint = Vector(0,0,0)
    self.lastHitAbsorb = false
    self.contactEntityIdMap = {}
    self.shieldContactCount = 0
    self.idleHeatAmount = 0
    self.isInCombat = false
    self.shieldEffectScalar = 0
    self.physicsEnabled = false
    self:SetUpdates(true)
end

function ExoShield:OnInitialized()
    Entity.OnInitialized(self)
end
function ExoShield:GetTechId() return kTechId.ExoShield end
function ExoShield:GetShieldHitPoints() return self.shieldHitPoints end
function ExoShield:GetWeight() return ExoShield.kWeight end
function ExoShield:GetOwner() return self:GetParent() end
function ExoShield:GetIsShieldActive() return self.isShieldActive end
function ExoShield:GetCanDieOverride() return false end
function ExoShield:GetCanBeHealed() return false end
function ExoShield:GetCanTakeDamageOverride() return self.isShieldActive end
function ExoShield:GetSurfaceOverride() return "nanoshield" end
function ExoShield:GetIsNanoShielded() return true end
function ExoShield:GetShieldTeam() return kMarineTeamType end
function ExoShield:GetShieldDistance() return ExoShield.kRadius end
function ExoShield:GetShieldAngleExtents() return math.atan(4*ExoShield.kCurveDepth/ExoShield.kWidth),math.atan(4*ExoShield.kCurveDepth/ExoShield.kWidth) end
function ExoShield:GetShieldProjectorCoordinates()
    local c=self:GetShieldCoords()
    if not c then return nil end
    c.origin=c.origin-c.zAxis*ExoShield.kRadius
    local a=Angles();a:BuildFromCoords(c)
    return c,a
end

function ExoShield:OnPrimaryAttack(player) self.isShieldDesired = true end
function ExoShield:OnPrimaryAttackEnd(player) self.isShieldDesired = false end
function ExoShield:OnTag(tagName) end
function ExoShield:OnUpdateAnimationInput(modelMixin)
    modelMixin:SetAnimationInput("activity_" .. self:GetExoWeaponSlotName(), "none")
end

-- One shield arm projects the full-width barrier (both halves). A second shield arm
-- feeds the same barrier: both emitters share one damage pool, so it is twice as strong.
function ExoShield.GetIsDualShield(parent)
    return parent ~= nil and kExoModuleTypes ~= nil and kExoModuleTypes.Shield ~= nil
        and parent.leftArmModuleType == kExoModuleTypes.Shield
        and parent.rightArmModuleType == kExoModuleTypes.Shield
end
-- With both emitters running, whichever arm raised the barrier first keeps owning it;
-- the second arm only feeds (reinforces) it, so nothing is rebuilt either way round.
function ExoShield:GetIsBarrierFeeder()
    local partner = self:GetPartnerShield()
    if not (partner and partner:GetIsShieldActive() and self.isShieldActive) then return false end
    local mine, theirs = self.shieldDeployChangeTime or 0, partner.shieldDeployChangeTime or 0
    if theirs ~= mine then return theirs < mine end
    return not self:GetIsLeftSlot()
end
function ExoShield:GetCoveredHalves()
    if self:GetIsBarrierFeeder() then return {} end
    return { "left", "right" }
end
function ExoShield:GetPartnerShield()
    local parent = self:GetParent()
    if not ExoShield.GetIsDualShield(parent) then return nil end
    local holder = parent.GetWeapon and parent:GetWeapon(ExoWeaponHolder.kMapName)
    if not holder then return nil end
    local other = self:GetIsLeftSlot() and holder:GetRightSlotWeapon() or holder:GetLeftSlotWeapon()
    return other and other:isa("ExoShield") and other or nil
end
-- Centre of the whole barrier (the seam between the halves).
function ExoShield:GetBarrierCentreCoords()
    local c = self:GetShieldCoords(nil, nil, "left")
    if not c then return nil end
    c.origin = c.origin - c.xAxis * (ExoShield.kWidth / 2)
    return c
end

function ExoShield:GetShieldCoords(xFraction,yFraction,half)
    local isLeft = half == nil and self:GetIsLeftSlot() or half == "left"
    local parent = self:GetParent()
    if not parent then return nil end
    local angles = Angles()
    angles:BuildFromCoords(parent:GetViewCoords())
    angles.roll = 0
    local coords = angles:GetCoords()
    -- Rigidly mounted on the arms: the arms are fixed in the pilot's view, so the barrier
    -- keeps one offset from the eye and turns through exactly the same angle as the aim
    -- (aim 30 degrees up and it tilts 30 degrees up, at the same distance from the arm).
    local eye = parent:GetEyePos()
    local levelHeight = parent:GetOrigin().y + ExoShield.kHeight/2 - eye.y
    coords.origin = eye + coords.yAxis * levelHeight
        + coords.zAxis * (ExoShield.kDistance-ExoShield.kCurveDepth/4)
        + coords.xAxis * (isLeft and ExoShield.kWidth/2 or -ExoShield.kWidth/2)
    if xFraction or yFraction then
        local x=((xFraction or .5)-.5)*ExoShield.kWidth
        local globalX=x+(isLeft and ExoShield.kWidth/2 or -ExoShield.kWidth/2)
        local z=-ExoShield.kCurveDepth*(globalX*globalX-ExoShield.kWidth*ExoShield.kWidth/4)/(ExoShield.kWidth*ExoShield.kWidth)
        local normal=(coords.zAxis+coords.xAxis*(2*ExoShield.kCurveDepth*globalX/(ExoShield.kWidth*ExoShield.kWidth))):GetUnit()
        local origin=coords.origin+coords.xAxis*x+coords.zAxis*z
            +coords.yAxis*((yFraction or .5)-.5)*ExoShield.kHeight
        return Coords.GetLookIn(origin,normal,coords.yAxis)
    end
    return coords
end

function ExoShield:UpdateHeat(dt)
    local now=Shared.GetTime()
    self.isInCombat=self.lastHitTime>0 and now<self.lastHitTime+ExoShield.kCombatDuration
    local floor=0
    if self.isShieldDeployed and not self.isShieldOverheated then
        local ramp=Clamp((now-self.shieldDeployChangeTime)/ExoShield.kIdleBaseHeatMaxDelay,0,1)
        floor=ExoShield.kIdleBaseHeatMin+(ExoShield.kIdleBaseHeatMax-ExoShield.kIdleBaseHeatMin)*ramp
        if self.isInCombat then floor=floor+ExoShield.kCombatBaseHeatExtra end
    end
    self.idleHeatAmount=floor
    if Server then
        local rate=0
        if self.isShieldOverheated then
            if now>=self.lastHitTime+ExoShield.kRechargeDelay then rate=ExoShield.kBrokenRechargePerSecond/ExoShield.kCapacity end
        elseif not self.isShieldDeployed then
            if now>=self.lastHitTime+ExoShield.kRechargeDelay then rate=ExoShield.kRechargePerSecond/ExoShield.kCapacity end
        else
            rate=self.isInCombat and ExoShield.kHeatCombatDrainRate or ExoShield.kHeatActiveDrainRate
        end
        self.shieldHitPoints = Clamp(self.shieldHitPoints + rate * ExoShield.kCapacity * dt, 0, ExoShield.kCapacity)
        self:SetHealth(self.shieldHitPoints)
        self.heatAmount=Clamp(self.heatAmount-rate*dt,floor,1)
        if self.isShieldOverheated and self.heatAmount<=ExoShield.kRecoveryHeat then self.isShieldOverheated=false end
    end
end

function ExoShield:AbsorbDamage(damage, point, absorbedProjectile)
    if not Server or not self.isShieldActive or damage <= 0 then return end
    -- Two emitters share the load: a hit on either half drains both equally,
    -- so the combined barrier holds twice the damage of a single one.
    local partner = self:GetPartnerShield()
    if partner and partner:GetIsShieldActive() then
        partner:ApplyAbsorbedDamage(damage * 0.5, point, absorbedProjectile)
        self:ApplyAbsorbedDamage(damage * 0.5, point, absorbedProjectile)
        return
    end
    self:ApplyAbsorbedDamage(damage, point, absorbedProjectile)
end
function ExoShield:ApplyAbsorbedDamage(damage, point, absorbedProjectile)
    if not self.isShieldActive or damage <= 0 then return end
    local absorbed = math.min(damage, self.shieldHitPoints)
    self.shieldHitPoints = math.max(0, self.shieldHitPoints - damage)
    self:SetHealth(self.shieldHitPoints)
    self.heatAmount = Clamp(self.heatAmount + absorbed / ExoShield.kCapacity, 0, 1)
    self.lastHitTime = Shared.GetTime()
    self.lastHitAbsorb = absorbedProjectile == true
    local coords=self:GetShieldCoords()
    self.lastHitPoint=point or (coords and coords.origin or self:GetOrigin())
    if not self.lastHitSoundTime or self.lastHitTime-self.lastHitSoundTime>=0.08 then
        StartSoundEffectAtOrigin(kHitSound,self.lastHitPoint)
        self.lastHitSoundTime=self.lastHitTime
    end
    if self.shieldHitPoints <= 0 then
        self.heatAmount = 1
        StartSoundEffectAtOrigin(kBreakSound,self.lastHitPoint)
        self:ClearContacts()
        self.isShieldOverheated = true
        self.isShieldActive = false
        self.isShieldDeployed = false
        self.shieldDeployChangeTime = Shared.GetTime()
        self:UpdatePhysics()
    end
end

function ExoShield:AbsorbProjectile(projectile)
    local damage = projectile:isa("WhipBomb") and (kWhipBombardDamage or 100)
        or (kBileBombDamage or 100)
    self:AbsorbDamage(damage * ExoShield.kCorrodeDamageScalar,projectile:GetOrigin(),true)
end

-- DamageTypes calls this hook for real hits; OverrideTakeDamage is not an engine callback.
function ExoShield:ModifyDamageTaken(damageTable, attacker, doer, damageType, hitPoint)
    if Server and self.isShieldActive and damageTable.damage > 0
        and (not attacker or not attacker.GetTeamNumber or attacker:GetTeamNumber() ~= self:GetTeamNumber()) then
        self:AbsorbDamage(damageTable.damage, hitPoint)
    end
    -- The capacity above owns damage; do not let LiveMixin subtract it a second time.
    damageTable.damage = 0
end

function ExoShield:ProcessMoveOnWeapon(player, input)
    self:UpdateHeat(input.time)
    local now = Shared.GetTime()
    local desired = self.isShieldDesired and not self.isShieldOverheated
    if desired ~= self.isShieldDeployed then
        self.isShieldDeployed = desired
        self.shieldDeployChangeTime = now
    end
    local wasActive = self.isShieldActive
    self.isShieldActive = self.isShieldDeployed and not self.isShieldOverheated
        and now >= self.shieldDeployChangeTime + ExoShield.kDeployDelay
        and player:GetIsAlive()
    if Server then
        self:UpdatePhysics()
        if self.isShieldActive and not wasActive then StartSoundEffectAtOrigin(kDeploySound,self:GetShieldCoords().origin) end
        if self.isShieldActive then self:UpdateZapping(input.time) else self:ClearContacts() end
    end
end

function ExoShield:GetShieldSegmentCoords(index, center)
    local halves = self:GetCoveredHalves()
    local n = ExoShield.kPhysicsSegments
    local h = math.min(#halves, math.floor((index - 1) / n) + 1)
    local i = (index - 1) % n + 1
    return self:GetShieldCoords((i - .5) / n, .5, halves[h])
end
function ExoShield:UpdatePhysics()
    local parent=self:GetParent()
    local center=self.isShieldActive and parent and parent:GetIsAlive() and self:GetShieldCoords() or nil
    local bodyCount = ExoShield.kPhysicsSegments * #self:GetCoveredHalves()
    if self.shieldBodies and #self.shieldBodies ~= bodyCount then
        for _,body in ipairs(self.shieldBodies) do Shared.DestroyCollisionObject(body) end
        self.shieldBodies=nil;self.shieldBody=nil;self.physicsEnabled=false
    end
    if center and not self.shieldBodies then
        self.shieldBodies={}
        local width=ExoShield.kWidth/ExoShield.kPhysicsSegments*math.sqrt(1+(4*ExoShield.kCurveDepth/ExoShield.kWidth)^2)+.02
        for i=1,bodyCount do
            local body=Shared.CreatePhysicsBoxBody(true,Vector(width/2,ExoShield.kHeight/2,ExoShield.kDepth/2),1,self:GetShieldSegmentCoords(i,center))
            body:SetEntity(self);body:SetPhysicsType(CollisionObject.Kinematic)
            body:SetGroup(PhysicsGroup.SmallStructuresGroup);body:SetTriggeringEnabled(true);body:SetGravityEnabled(false)
            self.shieldBodies[i]=body
        end
        self.shieldBody=self.shieldBodies[1] -- compatibility with existing cleanup checks
    end
    if self.shieldBodies then
        local enabled=center~=nil
        for i,body in ipairs(self.shieldBodies) do
            if center then body:SetCoords(self:GetShieldSegmentCoords(i,center)) end
            if enabled~=self.physicsEnabled then body:SetCollisionEnabled(enabled) end
        end
        self.physicsEnabled=enabled
    end
end
function ExoShield:DestroyPhysics()
    if self.shieldBodies then
        for _,body in ipairs(self.shieldBodies) do Shared.DestroyCollisionObject(body) end
        self.shieldBodies=nil;self.shieldBody=nil
    end
    self.physicsEnabled=false
    self:ClearContacts()
end

function ExoShield:OnParentKilled()
    self.isShieldDesired = false
    self.isShieldDeployed = false
    self.isShieldActive = false
    self:DestroyPhysics()
end

function ExoShield:OnUpdate(deltaTime)
    Entity.OnUpdate(self,deltaTime)
    local parent=self:GetParent()
    if not parent or not parent:GetIsAlive() then
        if self.isShieldActive or self.shieldBody then self:OnParentKilled() end
        return
    end
    if Client then self:UpdatePhysics() end
end

if Client then
    -- Visual-only tuning. Physics and hit detection use GetShieldCoords().
    ExoShield.kDeployInTime = 0.35   -- field grows out of the stump
    ExoShield.kDeployOutTime = 0.18  -- and collapses back into it
    ExoShield.kBeamWidth = 1.0

    local function Ease(x) return x * x * (3 - 2 * x) end

    -- Frame of an arm stump the barrier is projected from (world space, origin at the stump tip).
    function ExoShield:GetStumpFrame(parent, coords, leftSide)
        if leftSide == nil then leftSide = self:GetIsLeftSlot() end
        local localView = parent == Client.GetLocalPlayer() and not parent:GetIsThirdPerson()
        local source = localView and parent:GetViewModelEntity() or parent
        local names = localView and { leftSide and "bone_Claw_Arm" or "R_bone_Claw_Arm" }
            or { leftSide and "Exosuit_LWrist" or "Exosuit_RWrist", leftSide and "Exosuit_LElbow" or "Exosuit_RElbow" }
        local frame
        for _, name in ipairs(names) do
            if source and source:GetAttachPointIndex(name) >= 0 then frame = source:GetAttachPointCoords(name); break end
        end
        if frame and localView then frame = GetRenderCameraCoords() * frame end
        if frame and frame:GetIsFinite() then
            local f = Coords.GetIdentity()
            f.xAxis = frame.xAxis:GetUnit(); f.yAxis = frame.yAxis:GetUnit(); f.zAxis = frame.zAxis:GetUnit()
            f.origin = frame.origin + (localView and frame.xAxis * .26553 or Vector(0, 0, 0))
            return f
        end
        local f = Coords.GetIdentity()
        f.xAxis = coords.xAxis; f.yAxis = coords.yAxis; f.zAxis = coords.zAxis
        f.origin = parent:GetEyePos() + coords.xAxis * (leftSide and .65 or -.65) - coords.yAxis * .5 + coords.zAxis * .4
        return f
    end
    function ExoShield:GetStumpTip(parent, coords, leftSide)
        return self:GetStumpFrame(parent, coords, leftSide).origin
    end

    -- Barrier-wide coordinates: u runs 0..1 across both halves from screen-left, v 0..1 top to bottom.
    local function BarrierUV(point, centreOrigin, axes)
        local d = point - centreOrigin
        local u = (ExoShield.kWidth - d:DotProduct(axes.xAxis)) / (2 * ExoShield.kWidth)
        local v = 0.5 - d:DotProduct(axes.yAxis) / ExoShield.kHeight
        return Clamp(u, 0.02, 0.98), Clamp(v, 0.04, 0.96)
    end
    local function BarrierPoint(u, v, centreOrigin, axes)
        return centreOrigin + axes.xAxis * (ExoShield.kWidth - u * 2 * ExoShield.kWidth) - axes.yAxis * ((v - 0.5) * ExoShield.kHeight)
    end

    function ExoShield:UpdateEmitterLink(tip, target, coords, ease)
        local direction = target - tip
        local length = direction:GetLength()
        if length < .01 then if self.emitterLink then self.emitterLink:SetIsVisible(false) end return end
        if not self.emitterLink then
            self.emitterLink = Client.CreateRenderModel(RenderScene.Zone_Default)
            self.emitterLink:SetModel(Shared.GetModelIndex(ExoShield.kLinkModelName))
            self.emitterLink:SetCastsShadows(false); self.emitterLink:InstanceMaterials()
        end
        local link = Coords.GetLookIn(tip, direction * (1 / length), coords.yAxis)
        local width = ExoShield.kBeamWidth * (0.4 + 0.6 * ease)
        link.xAxis = link.xAxis * width; link.yAxis = link.yAxis * width
        link.zAxis = link.zAxis * length
        self.emitterLink:SetCoords(link); self.emitterLink:SetIsVisible(true)
        self.emitterLink:SetMaterialParameter("shieldOpacity", self.shieldEffectScalar)
        self.emitterLink:SetMaterialParameter("shieldHeat", self.heatAmount)
    end

    function ExoShield:GetHalfModel(half)
        self.halfModels = self.halfModels or {}
        local model = self.halfModels[half]
        if not model then
            model = Client.CreateRenderModel(RenderScene.Zone_Default)
            model:SetModel(Shared.GetModelIndex(half == "left" and ExoShield.kModelName or ExoShield.kRightModelName))
            model:SetCastsShadows(false)
            model:InstanceMaterials()
            self.halfModels[half] = model
        end
        return model
    end

    function ExoShield:HideVisuals()
        for _, model in pairs(self.halfModels or {}) do model:SetIsVisible(false) end
        if self.emitterLink then self.emitterLink:SetIsVisible(false) end
        self.attachLocal = nil
        self.visualCentre = nil
    end

    function ExoShield:OnUpdateRender()
        local parent = self:GetParent()
        local centre = self:GetBarrierCentreCoords()
        self:UpdateHeat(0)
        self:UpdateShieldDisplay(parent)
        if not centre or not parent:GetIsAlive() then self:HideVisuals(); return end
        local now = Shared.GetTime()
        local dt = Clamp(now - (self.lastRenderTime or now), 0, 0.1)
        self.lastRenderTime = now
        if self.isShieldActive then
            self.shieldEffectScalar = Clamp(self.shieldEffectScalar + dt / ExoShield.kDeployInTime, 0, 1)
        else
            self.shieldEffectScalar = Clamp(self.shieldEffectScalar - dt / ExoShield.kDeployOutTime, 0, 1)
        end
        if self.shieldEffectScalar <= 0 then self:HideVisuals(); return end

        local partner = self:GetPartnerShield()
        local ease = Ease(self.shieldEffectScalar)
        local isLeft = self:GetIsLeftSlot()
        local frame = self:GetStumpFrame(parent, centre, isLeft)
        local tip = frame.origin
        local covered = self:GetCoveredHalves()

        -- An arm that is feeding, or has just let go while the other arm still holds the
        -- barrier, draws only its beam into the shared barrier.
        if #covered == 0 or (not self.isShieldActive and partner and partner:GetIsShieldActive()) then
            for _, model in pairs(self.halfModels or {}) do model:SetIsVisible(false) end
            self.attachLocal = nil
            local pc = partner and partner.visualCentre
            if pc then
                local u, v = BarrierUV(tip, pc.origin, pc)
                local feedPoint = BarrierPoint(u, v, pc.origin, pc)
                self:UpdateEmitterLink(tip, tip + (feedPoint - tip) * (0.35 + 0.65 * ease), pc, ease)
            elseif self.emitterLink then
                self.emitterLink:SetIsVisible(false)
            end
            return
        end

        -- The barrier is fixed to the emitting arm: its offset from the stump is taken
        -- once when it deploys, so swinging the arm carries the shield along the same arc.
        if not self.attachLocal then
            -- Taking over from the other arm: keep the barrier exactly where it already is.
            local existing = partner and partner.visualCentre
            self.attachLocal = frame:GetInverse() * (existing or centre)
        end
        local target = frame * self.attachLocal
        self.visualCentre = target

        local feeding = partner ~= nil and partner:GetIsShieldActive() and (partner.shieldEffectScalar or 0) > 0
        local partnerEase = feeding and Ease(partner.shieldEffectScalar) or 0

        -- Where each stump projects onto the barrier: energy flows out from there.
        local emitU, emitV = BarrierUV(tip, target.origin, target)
        local emitPoint = BarrierPoint(emitU, emitV, target.origin, target)
        local emit2U, emit2V = 0.5, 0.5
        if feeding then emit2U, emit2V = BarrierUV(self:GetStumpTip(parent, centre, not isLeft), target.origin, target) end
        local hitU, hitV = BarrierUV(self.lastHitPoint, target.origin, target)
        local hitAge = self.lastHitTime > 0 and Clamp((now - self.lastHitTime) / .45, 0, 1) or 1

        -- Grow out of the stump while deploying.
        local scale = 0.15 + 0.85 * ease
        local pull = 0.35 + 0.65 * ease
        local rendered = {}
        for _, half in ipairs(covered) do
            rendered[half] = true
            local halfOrigin = target.origin + target.xAxis * (half == "left" and ExoShield.kWidth / 2 or -ExoShield.kWidth / 2)
            local visual = Coords.GetIdentity()
            visual.origin = emitPoint + (halfOrigin - emitPoint) * scale
            visual.origin = tip + (visual.origin - tip) * pull
            visual.xAxis = target.xAxis * scale; visual.yAxis = target.yAxis * scale; visual.zAxis = target.zAxis * scale
            local model = self:GetHalfModel(half)
            model:SetCoords(visual)
            model:SetIsVisible(true)
            model:SetMaterialParameter("shieldOpacity", math.min(1, self.shieldEffectScalar * 1.5))
            model:SetMaterialParameter("shieldHalf", half == "left" and 0 or 1)
            model:SetMaterialParameter("shieldDual", feeding and 1 or 0)
            model:SetMaterialParameter("shieldHeat", self.heatAmount)
            model:SetMaterialParameter("shieldEmit1U", emitU)
            model:SetMaterialParameter("shieldEmit1V", emitV)
            model:SetMaterialParameter("shieldEmit1", ease)
            model:SetMaterialParameter("shieldEmit2U", emit2U)
            model:SetMaterialParameter("shieldEmit2V", emit2V)
            model:SetMaterialParameter("shieldEmit2", partnerEase)
            model:SetMaterialParameter("shieldHitU", hitU)
            model:SetMaterialParameter("shieldHitV", hitV)
            model:SetMaterialParameter("shieldAbsorb", self.lastHitAbsorb and 1 or 0)
            model:SetMaterialParameter("shieldContact", self.shieldContactCount > 0 and 1 or 0)
            model:SetMaterialParameter("shieldHit", 1 - hitAge)
            model:SetMaterialParameter("shieldHitAge", hitAge)
        end
        for half, model in pairs(self.halfModels or {}) do
            if not rendered[half] then model:SetIsVisible(false) end
        end
        self:UpdateEmitterLink(tip, tip + (emitPoint - tip) * pull, target, ease)
    end
end

function ExoShield:OnDestroy()
    if self.shieldInstanceRegistered then
        gExoBarrierInstanceCount = math.max(0, (gExoBarrierInstanceCount or 1) - 1)
        self.shieldInstanceRegistered = false
    end
    self:DestroyPhysics()
    if Client and self.halfModels then
        for _, model in pairs(self.halfModels) do Client.DestroyRenderModel(model) end
        self.halfModels = nil
    end
    if Client and self.emitterLink then Client.DestroyRenderModel(self.emitterLink);self.emitterLink=nil end
    if Client and self.heatDisplayUI then Client.DestroyGUIView(self.heatDisplayUI);self.heatDisplayUI=nil end
    self:ClearContacts()
    Entity.OnDestroy(self)
end


function ExoShield:ClearContacts()
    self.contactEntityIdMap={}
    if Server then self.shieldContactCount=0 end
end
function ExoShield:GetIsEntityZappable(ent)
    return ent and HasMixin(ent,"Live") and HasMixin(ent,"Energy") and ent:GetIsAlive()
        and GetAreEnemies(self,ent)
end
function ExoShield:OnTriggerEntered(a,b)
    if not Server or not self.isShieldActive then return end
    local ent=a==self and b or a
    if self:GetIsEntityZappable(ent) then
        local id=ent:GetId()
        if self.contactEntityIdMap[id] then self.contactEntityIdMap[id]=self.contactEntityIdMap[id]+1
        elseif self.shieldContactCount<ExoShield.kMaxContacts then
            self.contactEntityIdMap[id]=1;self.shieldContactCount=self.shieldContactCount+1
        end
    end
end
function ExoShield:OnTriggerExited(a,b)
    if not Server then return end
    local ent=a==self and b or a
    if ent and self.contactEntityIdMap[ent:GetId()] then
        local id=ent:GetId()
        self.contactEntityIdMap[id]=self.contactEntityIdMap[id]-1
        if self.contactEntityIdMap[id]<=0 then
            self.contactEntityIdMap[id]=nil;self.shieldContactCount=math.max(0,self.shieldContactCount-1)
        end
    end
end
function ExoShield:UpdateZapping(dt)
    local coords=self:GetShieldCoords()
    if not coords then self:ClearContacts();return end
    for id in pairs(self.contactEntityIdMap) do
        local ent=Shared.GetEntity(id)
        local valid=self:GetIsEntityZappable(ent)
        if valid then
            local touching=false
            for _,half in ipairs(self:GetCoveredHalves()) do
                local hc=self:GetShieldCoords(nil,nil,half)
                local offset=ent:GetOrigin()-hc.origin
                local radius=ent.GetExtents and ent:GetExtents():GetLength() or .75
                local x=offset:DotProduct(hc.xAxis);local z=offset:DotProduct(hc.zAxis)
                local clampedX=Clamp(x,-ExoShield.kWidth/2,ExoShield.kWidth/2)
                local globalX=clampedX+(half=="left" and ExoShield.kWidth/2 or -ExoShield.kWidth/2)
                local surfaceZ=-ExoShield.kCurveDepth*(globalX*globalX-ExoShield.kWidth*ExoShield.kWidth/4)/(ExoShield.kWidth*ExoShield.kWidth)
                touching=touching or (math.abs(z-surfaceZ)<=ExoShield.kDepth/2+radius
                    and math.abs(offset:DotProduct(hc.yAxis))<=ExoShield.kHeight/2+radius
                    and math.abs(x)<=ExoShield.kWidth/2+radius)
            end
            valid=touching
        end
        if valid then
            ent:AddEnergy(-(ent:GetMaxEnergy()*ExoShield.kContactEnergyDrainRatePercent
                +ExoShield.kContactEnergyDrainRateFixed)*dt)
        else
            self.contactEntityIdMap[id]=nil
            self.shieldContactCount=math.max(0,self.shieldContactCount-1)
        end
    end
    if self.shieldContactCount>0 then
        local now=Shared.GetTime()
        if not self.lastContactSound or now-self.lastContactSound>.7 then
            StartSoundEffectAtOrigin(kHitSound,coords.origin)
            self.lastContactSound=now
        end
    end
end
if Client then
    function ExoShield:UpdateShieldDisplay(parent)
        if not parent or parent~=Client.GetLocalPlayer() then return end
        if not self.heatDisplayUI then
            self.heatDisplayUI=Client.CreateGUIView(800,800)
            self.heatDisplayUI:Load("lua/GUIExoArmDisplay.lua")
            self.heatDisplayUI:SetTargetTexture("*exo_claw_" .. self:GetExoWeaponSlotName())
        end
        self.heatDisplayUI:SetGlobal("displayMode",5)
        self.heatDisplayUI:SetGlobal("displayHeat",1-self.shieldHitPoints/ExoShield.kCapacity)
        self.heatDisplayUI:SetGlobal("displayHP",self.shieldHitPoints)
        self.heatDisplayUI:SetGlobal("displayMaxHP",ExoShield.kCapacity)
        self.heatDisplayUI:SetGlobal("displayFloor",self.idleHeatAmount)
        self.heatDisplayUI:SetGlobal("displayStatus",self.isShieldOverheated and "OVERHEAT"
            or not self.isShieldDesired and "OFF" or self.isInCombat and "COMBAT" or "ON")
    end
end

Shared.LinkClassToMap("ExoShield", ExoShield.kMapName, networkVars)
