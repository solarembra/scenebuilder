if not CLIENT then return end

--[[
DOCS

function kat_lightOverride.Enable(bool state)
    enables or disables the custom lighting

function kat_lightOverride.SetModelLighting(number lightDir,number r,number g, number b)
    https://wiki.facepunch.com/gmod/render.SetModelLighting
    except globally

function kat_lightOverride.LightingBandaid()
    call this function in a render context to "bandaid" apply the current lighting parameters for specific scenarios

function kat_lightOverride.ApplyCSMRenderOverride(Entity ent,bool state)
    manually force and entity to render as a ClientsideModel with the custom lighting
    use on entities that don't behave for some reason (engine ents)
    use sparingly, this function has a cost to it
    automatically disposes entities that are removed, don't worry about disposal

function kat_lightOverride.RestrictToAABB(bool,min,max)
    used to prevent lights outside the aabb from being rendered with expensive projtextures
    also prevents rendering of CSMRenderOverride ents outside of the AABB
]]
local MAX_DYNAMICLIGHTS_CL = 20

kat_lightOverride = kat_lightOverride or {
    originalFuncs = {},
}
local originalFuncs = kat_lightOverride.originalFuncs

local hooks = {}
local detouredFuncs

local IsValid = IsValid
local ScrW = ScrW
local ScrH = ScrH
local r_SuppressEngineLighting
local r_SetModelLighting
local r_ResetModelLighting
local r_SetAmbientLight
local r_RenderFlashlights = render.RenderFlashlights
local s_SetDrawColor = surface.SetDrawColor
local s_DrawRect = surface.DrawRect
local t_insert = table.insert
local c_Start3D = cam.Start3D
local c_End3D = cam.End3D
local c_Start2D = cam.Start2D
local c_End2D = cam.End2D

local projectedTextureFuncs = FindMetaTable("ProjectedTexture")
local pTex_SetPos = projectedTextureFuncs.SetPos
local pTex_SetFarZ = projectedTextureFuncs.SetFarZ
local pTex_SetBrightness = projectedTextureFuncs.SetBrightness
local pTex_SetColor = projectedTextureFuncs.SetColor
local pTex_SetAngles = projectedTextureFuncs.SetAngles
local pTex_Update = projectedTextureFuncs.Update
local entFuncs = FindMetaTable("Entity")
local e_SetPos = entFuncs.SetPos
local e_GetPos = entFuncs.GetPos
local e_SetAngles = entFuncs.SetAngles
local e_GetAngles = entFuncs.GetAngles
local e_SetMaterial = entFuncs.SetMaterial
local e_GetMaterial = entFuncs.GetMaterial
local e_SetColor = entFuncs.SetColor
local e_GetColor = entFuncs.GetColor
local e_SetupBones = entFuncs.SetupBones
local e_DrawModel = entFuncs.DrawModel
local vFuncs = FindMetaTable("Vector")
local v_WithinAABox = vFuncs.WithinAABox

local dynamicLights = {}
local dynamicLightsLastDraw = {}
local pTexPairs = {}
local currentBoxLighting = {
    [0] = Vector(0,0,0),
    [1] = Vector(0,0,0),
    [2] = Vector(0,0,0),
    [3] = Vector(0,0,0),
    [4] = Vector(0,0,0),
    [5] = Vector(0,0,0),
    ambient = Vector(0,0,0),
}
local lightingEnabled = false
local customDrawRealm = false
local notInAABB = function(pos)
    return false
end

local lightingFunc = function() --instead of passing values to setModelLighting, redefine this function stored in the stack instead for cheaper rendering
    r_SetModelLighting(0,0,0,0)
    r_SetModelLighting(1,0,0,0)
    r_SetModelLighting(2,0,0,0)
    r_SetModelLighting(3,0,0,0)
    r_SetModelLighting(4,0,0,0)
    r_SetModelLighting(5,0,0,0)
end

do --detour
    if not originalFuncs.DynamicLight then
        originalFuncs.DynamicLight = DynamicLight
    end

    if not originalFuncs.SuppressEngineLighting then
        originalFuncs.SuppressEngineLighting = render.SuppressEngineLighting
    end
    r_SuppressEngineLighting = originalFuncs.SuppressEngineLighting

    if not originalFuncs.SetModelLighting then
        originalFuncs.SetModelLighting = render.SetModelLighting
    end
    r_SetModelLighting = originalFuncs.SetModelLighting

    if not originalFuncs.ResetModelLighting then
        originalFuncs.ResetModelLighting = render.ResetModelLighting
    end
    r_ResetModelLighting = originalFuncs.ResetModelLighting

    if not originalFuncs.SetAmbientLight then
        originalFuncs.SetAmbientLight = render.SetAmbientLight
    end
    r_SetAmbientLight = originalFuncs.SetAmbientLight

    detouredFuncs = {
        DynamicLight = function(index, elight)
            local data = {}
            t_insert(dynamicLights,data)
            return data
        end,

        SuppressEngineLighting = function(suppress)
            customDrawRealm = suppress
            if suppress then
                r_ResetModelLighting(1,1,1)
            else
                lightingFunc()
            end
        end,

        SetModelLighting = function(lightDirection, red, green, blue)
            if not customDrawRealm then return end
            r_SetModelLighting(lightDirection, red, green, blue)
        end,

        ResetModelLighting = function(red, green, blue)
            if not customDrawRealm then return end
            r_ResetModelLighting(red, green, blue)
        end,

        SetAmbientLight = function(red, green, blue)
            if not customDrawRealm then return end
            r_SetAmbientLight(red, green, blue)
        end,
    }
end

--[[
i understand that wrapping adds slight overhead to calls of these functions versus just redefining them live
but good addons will probably localize render funcs so i wanna detour it before they do if i can
]]--
local DisposeAllocatedProjTextures
do --(ENTRY POINT) control
    local selectedFunc_DynamicLight = originalFuncs.DynamicLight
    local selectedFunc_SuppressEngineLighting = originalFuncs.SuppressEngineLighting
    local selectedFunc_SetModelLighting = originalFuncs.SetModelLighting
    local selectedFunc_ResetModelLighting = originalFuncs.ResetModelLighting
    local selectedFunc_SetAmbientLight = originalFuncs.SetAmbientLight

    DynamicLight = function(index, elight)
        return selectedFunc_DynamicLight(index, elight)
    end

    render.SuppressEngineLighting = function(suppress)
        return selectedFunc_SuppressEngineLighting(suppress)
    end

    render.SetModelLighting = function(lightDirection, red, green, blue)
        return selectedFunc_SetModelLighting(lightDirection, red, green, blue)
    end

    render.ResetModelLighting = function(red, green, blue)
        return selectedFunc_ResetModelLighting(red, green, blue)
    end

    render.SetAmbientLight = function(red, green, blue)
        return selectedFunc_SetAmbientLight(red, green, blue)
    end

    function kat_lightOverride.Enable(bool)
        lightingEnabled = bool

        if bool then
            selectedFunc_DynamicLight = detouredFuncs.DynamicLight
            selectedFunc_SuppressEngineLighting = detouredFuncs.SuppressEngineLighting
            selectedFunc_SetModelLighting = detouredFuncs.SetModelLighting
            selectedFunc_ResetModelLighting = detouredFuncs.ResetModelLighting
            selectedFunc_SetAmbientLight = detouredFuncs.SetAmbientLight
            hook.Add("PreDrawOpaqueRenderables","kat_projtextures",hooks.ProjTextureHook,HOOK_HIGH)
            hook.Add("PreRender","kat_localizedlighting",hooks.PreRenderHook,HOOK_HIGH)
            hook.Add("PrePlayerDraw","kat_localizedlighting",function()
                lightingFunc()
            end,HOOK_HIGH)
        else
            selectedFunc_DynamicLight = originalFuncs.DynamicLight
            selectedFunc_SuppressEngineLighting = originalFuncs.SuppressEngineLighting
            selectedFunc_SetModelLighting = originalFuncs.SetModelLighting
            selectedFunc_ResetModelLighting = originalFuncs.ResetModelLighting
            selectedFunc_SetAmbientLight = originalFuncs.SetAmbientLight
            hook.Remove("PreDrawOpaqueRenderables","kat_projtextures")
            hook.Remove("PreRender","kat_localizedlighting")
            hook.Remove("PrePlayerDraw","kat_localizedlighting")
            DisposeAllocatedProjTextures()

            c_Start3D()
            r_SuppressEngineLighting(false)
            c_End3D()
        end
    end

    function kat_lightOverride.SetModelLighting(lightDir,r,g,b)
        local chosenDirLighting = currentBoxLighting[lightDir]
        chosenDirLighting.x = r
        chosenDirLighting.y = g
        chosenDirLighting.z = b

        --what the actual fuck has the addy made me do now
        local _00 = currentBoxLighting[0].x
        local _01 = currentBoxLighting[0].y
        local _02 = currentBoxLighting[0].z

        local _10 = currentBoxLighting[1].x
        local _11 = currentBoxLighting[1].y
        local _12 = currentBoxLighting[1].z

        local _20 = currentBoxLighting[2].x
        local _21 = currentBoxLighting[2].y
        local _22 = currentBoxLighting[2].z

        local _30 = currentBoxLighting[3].x
        local _31 = currentBoxLighting[3].y
        local _32 = currentBoxLighting[3].z

        local _40 = currentBoxLighting[4].x
        local _41 = currentBoxLighting[4].y
        local _42 = currentBoxLighting[4].z

        local _50 = currentBoxLighting[5].x
        local _51 = currentBoxLighting[5].y
        local _52 = currentBoxLighting[5].z

        local _60 = currentBoxLighting.ambient.x
        local _61 = currentBoxLighting.ambient.y
        local _62 = currentBoxLighting.ambient.z

        --local _a0 = chosenDirLighting.ambient.z
        lightingFunc = function() --stack upvalue autism™
            if customDrawRealm then return end
            r_SuppressEngineLighting(true)
            r_SetModelLighting(0,_00,_01,_02)
            r_SetModelLighting(1,_10,_11,_12)
            r_SetModelLighting(2,_20,_21,_22)
            r_SetModelLighting(3,_30,_31,_32)
            r_SetModelLighting(4,_40,_41,_42)
            r_SetModelLighting(5,_50,_51,_52)
            r_SetAmbientLight(_60,_61,_62)
        end
    end

    function kat_lightOverride.RestrictToAABB(bool,max,min)
        if bool then
            local AABBMax = bool and max or Vector(0,0,0)
            local AABBMin = bool and min or Vector(0,0,0)

            notInAABB = function(pos)
                return not v_WithinAABox(pos,AABBMax,AABBMin)
            end
        else
            notInAABB = function(pos)
                return false
            end
        end
    end

    function kat_lightOverride.LightingBandaid()
        lightingFunc()
    end
end

do --suppress engine lighting completely and replace with desired ambient lighting
    function hooks.PreRenderHook()
        dynamicLightsLastDraw = dynamicLights
        dynamicLights = {}

        c_Start3D()
        lightingFunc()
        c_End3D()
    end
end

do --replace dynamiclights with projected texture
    local function allocatedProjTexture(i)
        local pTex = pTexPairs[i]
        if IsValid(pTex) then return pTex end

        local projTexture = ProjectedTexture()
        projTexture:SetFOV(179.999)
        projTexture:SetNearZ(0.1)
        projTexture:SetTexture("particle\\Particle_Glow_05")
        projTexture:SetLinearAttenuation(2.5)
        pTexPairs[i] = projTexture
        return projTexture
    end

    DisposeAllocatedProjTextures = function()
        for i = 1,MAX_DYNAMICLIGHTS_CL * 2 do
            local pTex = pTexPairs[i]
            if not IsValid(pTex) then continue end
            pTex:Remove()
        end
    end

    local ANG_UP = Angle(90,0,0)
    local ANG_DOWN = Angle(-90,0,0)
    local color = Color(255,255,255)

    function hooks.ProjTextureHook()
        c_Start2D()
        s_SetDrawColor(0, 0, 0, 255)
        s_DrawRect(0, 0, ScrW(), ScrH())
        c_End2D()

        local lightsDrawn = 0
        for i = 1,#dynamicLightsLastDraw do
            if lightsDrawn == MAX_DYNAMICLIGHTS_CL then break end

            local data = dynamicLightsLastDraw[i]
            if not data then break end

            local pos = data.Pos or data.pos
            if not pos then continue end

            local size = data.Size or data.size
            if not size then continue end

            local brightness = data.Brightness or data.brightness
            if not brightness then continue end

            if size < 50 then continue end
            if size > 1024 then size = 1024 end
            if notInAABB(pos) then continue end

            color.r = data.r
            color.g = data.g
            color.b = data.b

            lightsDrawn = lightsDrawn + 1
            local upPTex = allocatedProjTexture(lightsDrawn)
            pTex_SetPos(upPTex,pos)
            pTex_SetFarZ(upPTex,size)
            pTex_SetBrightness(upPTex,brightness)
            pTex_SetColor(upPTex,color)
            pTex_SetAngles(upPTex,ANG_UP)
            pTex_Update(upPTex)

            lightsDrawn = lightsDrawn + 1
            local downPTex = allocatedProjTexture(lightsDrawn)
            pTex_SetPos(downPTex,pos)
            pTex_SetFarZ(downPTex,size)
            pTex_SetBrightness(downPTex,brightness)
            pTex_SetColor(downPTex,color)
            pTex_SetAngles(downPTex,ANG_DOWN)
            pTex_Update(downPTex)
        end

        local allocatedLightCount = #pTexPairs
        if lightsDrawn < allocatedLightCount then
            for i = lightsDrawn + 1,allocatedLightCount do
                if pTexPairs[i] then
                    pTexPairs[i]:Remove()
                    pTexPairs[i] = nil
                end
            end
        end
    end
end

do --manually replace bad engine types with custom renders (use sparingly, costly!)
    local CSModels = {}
    local EntModels = {} --which CSM is this ent using
    local RenderOverrides = {}
    local CSModelsInUse = setmetatable({},{__index = function(t,k)
        local nT = {}
        t[k] = nT
        return nT
    end})

    local function DeallocateCSModelLightingOverride(ent)
        if not ent.kat_CSMOverride then return end
        local model = EntModels[ent]

        if not model then return end
        EntModels[ent] = nil
        CSModelsInUse[model][ent] = nil

        if ent.RenderOverride == RenderOverrides[ent] then ent.RenderOverride = nil end
        RenderOverrides[ent] = nil

        if next(CSModelsInUse[model]) ~= nil then return end
        CSModels[model]:Remove()
        CSModels[model] = nil
    end

    local function AllocateCSModelLightingOverride(ent)
        if not ent.kat_CSMOverride then return end

        local model = ent:GetModel()
        CSModelsInUse[model][ent] = true
        EntModels[ent] = model

        local csm = CSModels[model]
        if not csm then
            csm = ClientsideModel(model)
            csm:SetNoDraw(true)
            CSModels[model] = csm
        end

        local overrideFunc = function(self,flags)
            local pos = e_GetPos(ent)
            if not lightingEnabled or notInAABB(pos) then
                return
            end

            lightingFunc()
            e_SetPos(csm,pos)
            e_SetAngles(csm,e_GetAngles(ent))
            e_SetColor(csm,e_GetColor(ent))
            e_SetMaterial(csm,e_GetMaterial(ent))

            local function draw()
                e_SetupBones(csm)
                e_DrawModel(csm)
            end
            draw()
            r_RenderFlashlights(draw)
        end

        RenderOverrides[ent] = overrideFunc
        ent.RenderOverride = overrideFunc
    end

    function kat_lightOverride.ApplyCSMRenderOverride(ent,bool)
        if not IsValid(ent) then error("Tried to use a NULL entity!") end

        if bool then
            ent.kat_CSMOverride = true
            AllocateCSModelLightingOverride(ent)
        else
            DeallocateCSModelLightingOverride(ent)
            ent.kat_CSMOverride = nil
        end
    end

    hook.Add("NetworkEntityCreated","kat_localizedlighting",function(ent)
        AllocateCSModelLightingOverride(ent)
    end)

    hook.Add("EntityRemoved","kat_localizedlighting",function(ent)
        DeallocateCSModelLightingOverride(ent)
    end)
end