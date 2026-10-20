-- ======= Copyright (c) 2003-2013, Unknown Worlds Entertainment, Inc. All rights reserved. =====
--
-- lua\ExoVariantMixin.lua
--
-- ==============================================================================================

Script.Load("lua/Globals.lua")
Script.Load("lua/NS2Utility.lua")

ExoVariantMixin = CreateMixin(ExoVariantMixin)
ExoVariantMixin.type = "ExoVariant"

ExoVariantMixin.networkVars =
{
    exoVariant = "enum kExoVariants"
}


function ExoVariantMixin:__initmixin()
    
    PROFILE("ExoVariantMixin:__initmixin")
    
    self.exoVariant = kDefaultExoVariant
    if Server then
        self.lastExoVariant = kDefaultExoVariant
    end

    if Client then
        self.dirtySkinState = false
        self.clientExoVariant = nil
    end

end

function ExoVariantMixin:GetExoVariant()
    return self.exoVariant
end

function ExoVariantMixin:SetExoVariant(variant)
    self.exoVariant = variant
end

if Server then

    function ExoVariantMixin:OnClientUpdated(client, isPickup)
        Player.OnClientUpdated(self, client, isPickup)

        local data = client.variantData
        if data == nil or isPickup then
            return
        end

        if GetHasVariant(kExoVariantsData, data.exoVariant, client) or client:GetIsVirtual() then
            self.exoVariant = data.exoVariant
            self.lastExoVariant = self.exoVariant
        else
            Log("ERROR: Client tried to request Exo variant they do not have yet")
        end
    end

    function ExoVariantMixin:TransferExoVariant(exosuit)
        self:SetExoVariant(exosuit:GetExoVariant())
    end

end


if Client then
    Script.Load("lua/Weapons/ExoSkinModelSlots.lua")

    -- Cache by material identity, not weapon class: mixed models have different
    -- slots even when their left-hand weapons are identical.
    local skinMaterials = {}
    local materialRoot = "models/marine/exosuit/"
    local skinnableParts = {
        "exosuit", "claw", "claw_view", "minigun", "minigun_view",
        "railgun", "railgun_view", "forearm", "charged_plasma",
    }
    local adaptedClawSkins = { forge = true, sandstorm = true, chroma = true }
    for variant, data in ipairs(kExoVariantsData) do
        if variant ~= kDefaultExoVariant then
            local name = string.lower(data.displayName)
            local materials = {}
            for _, part in ipairs(skinnableParts) do
                local suffix = name
                if (part == "claw" or part == "claw_view") and adaptedClawSkins[name] then
                    suffix = "mixed_" .. name
                end
                materials[part] = PrecacheAsset(materialRoot .. part .. "_" .. suffix .. ".material")
            end
            -- Chroma is the stock finish with its own cockpit texture.
            if variant == kExoVariants.chroma then
                materials.exosuit_view = PrecacheAsset(materialRoot .. "exosuit_view_chroma.material")
            end
            skinMaterials[variant] = materials
        end
    end

    local function ApplySkin(model, modelName, variant)
        local slots = kExoSkinModelSlots[modelName]
        if not slots then
            return false
        end
        -- Clears overrides left behind by a different skin or loadout. Screens,
        -- status panels, energy emitters and icons retain their authored materials.
        model:ClearOverrideMaterials()
        local materials = skinMaterials[variant]
        if materials then
            for index, part in pairs(slots) do
                if materials[part] then
                    model:SetOverrideMaterial(index, materials[part])
                end
            end
        end
        return true
    end

    function ExoVariantMixin:OnExoSkinChanged()
        self.dirtySkinState = true
    end

    function ExoVariantMixin:OnModelChanged(hasModel)
        if hasModel then
            self.dirtySkinState = true
        end
    end

    function ExoVariantMixin:OnUpdate(deltaTime)
        if not Shared.GetIsRunningPrediction() and self.clientExoVariant ~= self.exoVariant then
            self.dirtySkinState = true
        end
    end

    function ExoVariantMixin:OnUpdatePlayer(deltaTime)
        ExoVariantMixin.OnUpdate(self, deltaTime)
    end

    function ExoVariantMixin:OnUpdateRender()
        PROFILE("ExoVariantMixin:OnUpdateRender")
        local worldModel = self:GetRenderModel()
        local modelName = self:GetModelName()
        local localExo = self:isa("Exo") and self:GetIsLocalPlayer()
        local viewEntity = localExo and self:GetViewModelEntity() or nil
        local viewModel = viewEntity and viewEntity:GetRenderModel() or nil
        local viewName = viewEntity and viewEntity:GetModelName() or nil

        if self.clientExoVariant ~= self.exoVariant
            or self.skinWorldModel ~= worldModel or self.skinWorldName ~= modelName
            or self.skinViewModel ~= viewModel or self.skinViewName ~= viewName
            or self.skinViewEntity ~= viewEntity then
            self.dirtySkinState = true
        end
        if not self.dirtySkinState then
            return
        end
        if not worldModel or not worldModel:GetReadyForOverrideMaterials() then
            return false
        end
        -- A local player's view entity may be created a frame after its world model.
        if localExo and (not viewModel or not viewModel:GetReadyForOverrideMaterials()) then
            return false
        end
        if not ApplySkin(worldModel, modelName, self.exoVariant) then
            return false
        end
        if localExo and not ApplySkin(viewModel, viewName, self.exoVariant) then
            return false
        end
        self:SetHighlightNeedsUpdate()
        if viewEntity then
            viewEntity:SetHighlightNeedsUpdate()
        end
        self.skinWorldModel = worldModel
        self.skinWorldName = modelName
        self.skinViewModel = viewModel
        self.skinViewName = viewName
        self.skinViewEntity = viewEntity
        self.clientExoVariant = self.exoVariant
        self.dirtySkinState = false
    end
end
