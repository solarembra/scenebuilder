if not SERVER then return end

AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

function ENT:InitializeSV()

end

function ENT:StartTouch(e)

end

function ENT:EndTouch(e)

end

hook.Add("PhysgunDrop","kat_zonecontroller",function(_,e)
    if e:GetClass() ~= "kat_zonecontroller" then return end
    e:GetPhysicsObject():EnableMotion(false)
end)

do --spawn function
    local function Spawn(ply, Data)
        local ent = ents.Create("kat_zonecontroller")
        if not ent:IsValid() then return end

        duplicator.DoGeneric(ent, Data)
        ent:Spawn()
        ent:Activate()
        duplicator.DoGenericPhysics(ent, pl, Data)

        local physObj = ent:GetPhysicsObject()
        if physObj:IsValid() then physObj:Wake() end

        return ent
    end

    function ENT:SpawnFunction(ply, tr, class)
        return Spawn(ply, {
            Pos = tr.HitPos + Vector(0, 0, 21),
            Angle = Angle(0,0,0),
            Model = "models/maxofs2d/cube_tool.mdl"
        })
    end
end