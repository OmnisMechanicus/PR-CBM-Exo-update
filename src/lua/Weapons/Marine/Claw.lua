-- ======= Copyright (c) 2003-2012, Unknown Worlds Entertainment, Inc. All rights reserved. =====

--

-- lua\Weapons\Marine\Claw.lua

--

--    Created by:   Brian Cronin (brianc@unknownworlds.com)

--

-- ========= For more information, visit us at http://www.unknownworlds.com =====================



Script.Load("lua/DamageMixin.lua")

Script.Load("lua/Weapons/Marine/ExoWeaponSlotMixin.lua")

Script.Load("lua/TechMixin.lua")

Script.Load("lua/TeamMixin.lua")



local kClawSwingSound=PrecacheAsset("sound/NS2.fev/marine/heavy/punch")
class 'Claw' (Entity)



Claw.kMapName = "Claw"



local networkVars =

{

    clawAttacking = "private boolean",

    clawPunchUntil = "private time",

    lastClawHitTime = "private time",

    nextClawSwingTime = "private time",

    hasClawHit = "private boolean"

}



local kClawRange = 2.8



AddMixinNetworkVars(TechMixin, networkVars)

AddMixinNetworkVars(TeamMixin, networkVars)

AddMixinNetworkVars(ExoWeaponSlotMixin, networkVars)



local function GetIsDualClaw(player)

    return player and kExoModuleTypes

        and player.leftArmModuleType == kExoModuleTypes.Claw

        and player.rightArmModuleType == kExoModuleTypes.Claw

end



local function GetIsHandScopedClaw(player)

    return GetIsDualClaw(player) or (player and kExoModuleTypes.Shield

        and player.leftArmModuleType == kExoModuleTypes.Shield

        and player.rightArmModuleType == kExoModuleTypes.Claw)

end



local kDualClawPunchDuration = 26 / 30



local function GetOtherClaw(self, player)

    local holder = player and player:GetWeapon(ExoWeaponHolder.kMapName)

    if holder then

        if self:GetIsLeftSlot() then

            return holder:GetRightSlotWeapon()

        end

        return holder:GetLeftSlotWeapon()

    end

end



function Claw:OnCreate()



    Entity.OnCreate(self)

    

    InitMixin(self, TechMixin)

    InitMixin(self, TeamMixin)

    InitMixin(self, DamageMixin)

    InitMixin(self, ExoWeaponSlotMixin)

    

    self.clawAttacking = false

    self.clawPunchUntil = 0

    self.lastClawHitTime = 0

    self.hasClawHit = false

    self.nextClawSwingTime = 0

    

end



function Claw:GetIsAffectedByWeaponUpgrades()

    return true

end



function Claw:GetMeleeBase()

    return 1, 0.8

end



function Claw:GetMeleeOffset()

    return 0.0

end



-- Input-driven swing cues survive locomotion blends that discard animation tags.
-- Every hand owns its timer and emitter, including simultaneous dual punches.
function Claw:PlayClawSwingSound(now)
    if Predict then return end
    local player=self:GetParent()
    if not player then return end
    if Client then
        if player~=Client.GetLocalPlayer() or not Client.GetIsControllingPlayer() then return end
        if self.lastClientClawSwingTime and now-self.lastClientClawSwingTime<kDualClawPunchDuration*.75 then return end
        self.lastClientClawSwingTime=now
        if self.clawSwingSound then Client.DestroySoundEffect(self.clawSwingSound);self.clawSwingSound=nil end
        self.clawSwingSound=Client.CreateSoundEffect(Shared.GetSoundIndex(kClawSwingSound))
        if self.clawSwingSound then
            self.clawSwingSound:Start()
            self:UpdateWeaponSound(self.clawSwingSound,1)
        end
    elseif Server then
        StartSoundEffectAtOrigin(kClawSwingSound,self:GetWeaponSoundCoords().origin,1,player)
    end
end
function Claw:UpdateClawSwingSound()
    local player=self:GetParent()
    if not self.clawAttacking or not player or not player:GetIsAlive() then return end
    local now=Shared.GetTime()
    if now+0.0001>=(self.nextClawSwingTime or 0) then
        self.nextClawSwingTime=now+kDualClawPunchDuration
        self:PlayClawSwingSound(now)
    end
end

function Claw:OnPrimaryAttack(_)

    local player = self:GetParent()

    if GetIsHandScopedClaw(player) and not self.clawAttacking then

        local now = Shared.GetTime()

        self.clawPunchUntil = now + kDualClawPunchDuration

        local other = GetIsDualClaw(player) and GetOtherClaw(self, player) or nil

        if other and (other.clawAttacking or other.clawPunchUntil > now) then

            -- Join the current stroke and give the combined pose a full cycle.

            -- Both arms remain active even if either button is released early.

            other.clawPunchUntil = math.max(other.clawPunchUntil, self.clawPunchUntil)

            self.clawPunchUntil = other.clawPunchUntil

        end

    end

    self.clawAttacking = true

    self:UpdateClawSwingSound()

end



function Claw:OnPrimaryAttackEnd(_)

    self.clawAttacking = false

end



function Claw:GetDeathIconIndex()

    return kDeathMessageIcon.Claw

end



function Claw:ProcessMoveOnWeapon(player, input)
    self:UpdateClawSwingSound()
end



function Claw:GetWeight()

    return kClawWeight

end



function Claw:OnTag(tagName)



    PROFILE("Claw:OnTag")



    local player = self:GetParent()

    if player then

    

        if GetIsHandScopedClaw(player) then

            local side = self:GetExoWeaponSlotName()

            if tagName == "claw_hit_" .. side then

                local now = Shared.GetTime()

                -- Entering the combined clip must not repeat a hit already

                -- dealt by this hand during the same native punch interval.

                if not self.hasClawHit or now - self.lastClawHitTime >= kDualClawPunchDuration - 0.0001 then

                    self.lastClawHitTime = now

                    self.hasClawHit = true

                    AttackMeleeCapsuleAll(self, player, kClawDamage, kClawRange)

                end

            elseif tagName == side .. "_claw_attack_start" or tagName == "dual_claw_attack_start" then

                -- Sound is scheduled once per hand; blended/repeated tags only drive melee damage.

            end

        elseif tagName == "hit" then

            AttackMeleeCapsuleAll(self, player, kClawDamage, kClawRange)

        elseif tagName == "claw_attack_start" then

            -- Sound is scheduled once per hand; blended/repeated tags only drive melee damage.

        end

        

    end

    

end



function AttackMeleeCapsuleAll(weapon, player, damage, range, optionalCoords, altMode, filter)



    local targets = {}

    local didHit, target, endPoint, direction, surface, startPoint, trace



    if not filter then

        filter = EntityFilterTwo(player, weapon)

    end



    -- loop upto 20 times just to go through any soft targets.

    -- Stops as soon as nothing is hit or a non-soft target is hit

    for i = 1, 20 do



        local traceFilter = function(test)

            return EntityFilterList(targets)(test) or filter(test)

        end



        -- Enable tracing on this capsule check, last argument.

        didHit, target, endPoint, direction, surface, startPoint, trace = CheckMeleeCapsule(weapon, player, damage, range, optionalCoords, true, 1, nil, traceFilter)

        local alreadyHitTarget = target ~= nil and table.icontains(targets, target)



        if didHit and not alreadyHitTarget then

            weapon:DoDamage(damage, target, endPoint, direction, surface, altMode)

        end



        if target and not alreadyHitTarget then

            table.insert(targets, target)

        end



        if not target then

            break

        end



    end



    HandleHitregAnalysis(player, startPoint, endPoint, trace)



    local lastTarget = targets[#targets]



    -- Handle Stats

    if Server then



        local parent = weapon and weapon.GetParent and weapon:GetParent()

        if parent and weapon.GetTechId then



            -- Drifters, buildings and teammates don't count towards accuracy as hits or misses

            if (lastTarget and lastTarget:isa("Player") and GetAreEnemies(parent, lastTarget)) or lastTarget == nil then



                local steamId = parent:GetSteamId()

                if steamId then

                    StatsUI_AddAccuracyStat(steamId, weapon:GetTechId(), lastTarget ~= nil, lastTarget and lastTarget:isa("Onos"), weapon:GetParent():GetTeamNumber())

                end

            end

            GetBotAccuracyTracker():AddAccuracyStat(parent:GetClient(), lastTarget ~= nil, kBotAccWeaponGroup.Melee)

        end

    end



    return didHit, lastTarget, endPoint, surface



end



function Claw:OnUpdateAnimationInput(modelMixin)

    -- Same as CBM's single claw: the button drives the input directly and the
    -- dual-claw graph plays each punch to its end before blending back to idle.
    local activity = self.clawAttacking and "primary" or "none"

    modelMixin:SetAnimationInput("activity_" .. self:GetExoWeaponSlotName(), activity)

end



if Client then
    function Claw:OnUpdateRender()
        local parent = self:GetParent()
        if not parent or parent ~= Client.GetLocalPlayer() then return end
        if self.clawSwingSound then
            if self.clawSwingSound:GetIsPlaying() then self:UpdateWeaponSound(self.clawSwingSound,1)
            else Client.DestroySoundEffect(self.clawSwingSound);self.clawSwingSound=nil end
        end
        if not self.armDisplay then
            self.armDisplay = Client.CreateGUIView(800,800)
            self.armDisplay:Load("lua/GUIExoArmDisplay.lua")
            self.armDisplay:SetTargetTexture(self:GetIsLeftSlot() and "*exo_claw_left" or "*exo_claw_right")
            self.armDisplay:SetGlobal("displaySide", self:GetIsLeftSlot() and "left" or "right")
        end
    end
    function Claw:OnDestroy()
        if self.clawSwingSound then Client.DestroySoundEffect(self.clawSwingSound);self.clawSwingSound=nil end
        Entity.OnDestroy(self)
        if self.armDisplay then Client.DestroyGUIView(self.armDisplay);self.armDisplay=nil end
    end
end

Shared.LinkClassToMap("Claw", Claw.kMapName, networkVars)
