--[[
    Avatar Copier v23.0
    LocalScript (client side only). Puts another user's avatar (or an NPC's
    look) on your own character: body parts, body shape, head, clothing and
    accessories. Animations are never touched, the game keeps playing them.

    Notes
    * Only you see the result. Other players still see your real avatar.
    * Your original look is snapshotted before the first change, so the
      Restore button and the exit confirmation can put it back.
    * Banned or deleted accounts work on a best-effort basis: if Roblox still
      returns any appearance data for the ID it can be copied.

    v23: HOTKEYS.
      - Settings -> "Enable hotkeys" master switch + a rebindable key for:
          Show / hide window, Copy selected avatar, Restore original,
          3D preview, Focus search box.
      - Click a key button, then press the new key.
        Esc = cancel, Backspace = clear the binding.
      - "Reset hotkeys" restores the defaults.
      - Bindings are saved to AvatarCopier_hotkeys.json when the executor
        supports writefile/readfile (otherwise they last for the session).
      - Hotkeys are ignored while you type in a text box.
      - Settings is now scrollable.

    v22: NPC support.
      - NPCs (any Model with a Humanoid that is not a player) can be searched,
        selected, previewed in 3D and copied just like players.
      - "NPC" button next to Search: NPC-only mode (empty search lists all NPCs).
      - "NPC Scanner" in the header: scans the whole workspace and lists every
        NPC with rig type and distance, with Select / Copy buttons per NPC.
      - NPC and your rig must match (R15 -> R15, R6 -> R6).
]]

local DEBUG = true
local function log(...)
    if DEBUG then
        print("[AvatarCopier]", ...)
    end
end

--------------------------------------------------------------------
-- SERVICES
--------------------------------------------------------------------
local Players = game:GetService("Players")
local UserService = game:GetService("UserService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "AvatarCopier_v23"
for _, name in ipairs({ "AvatarCopier_v17", "AvatarCopier_v20", "AvatarCopier_v21", "AvatarCopier_v22", GUI_NAME }) do
    local old = playerGui:FindFirstChild(name)
    if old then
        old:Destroy() -- its Destroying handler restores the original avatar
    end
end

local Connections = {}
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

--------------------------------------------------------------------
-- SETTINGS / STATE
--------------------------------------------------------------------
local Settings = {
    MaxResults = 20,      -- 1..100
    KeepOnRespawn = true, -- re-apply the copy after you respawn
    CopyShape = true,     -- copy the target's body shape (players only; NPCs always copy shape)
}

local SelectedAvatar = {
    Active = false,
    UserId = nil,
    Username = nil,
    DisplayName = nil,
    Source = nil, -- the userData table that was copied (player or NPC)
}

local State = {
    selectedUser = nil,
    copying = false,
    busy = 0,             -- number of in-flight apply/restore operations
    searchTimer = nil,
    searchToken = 0,
    renderToken = 0,
    respawnToken = 0,
    selectToken = 0,
    npcOnly = false,      -- NPC-only search mode
    mainPosition = UDim2.fromScale(0.5, 0.5),
    floatPosition = nil,
    abort = false,        -- set when the user confirmed exit
    shuttingDown = false,
    destroyed = false,
}

local function dead()
    return State.destroyed or State.abort
end

local userInfoCache = {}
local searchCache = {}
local DataCache = {}
local DataLoading = {}

local EMPTY_HINT = "Search for a player or NPC to see their avatar here.\nBanned or deleted accounts: use the numeric user ID."

--------------------------------------------------------------------
-- THEME / UI HELPERS
--------------------------------------------------------------------
local C = {
    bg = Color3.fromRGB(24, 25, 29),
    panel = Color3.fromRGB(32, 34, 40),
    panel2 = Color3.fromRGB(42, 45, 53),
    line = Color3.fromRGB(56, 60, 70),
    text = Color3.fromRGB(235, 237, 241),
    sub = Color3.fromRGB(142, 148, 160),
    dim = Color3.fromRGB(96, 101, 112),
    accent = Color3.fromRGB(86, 196, 148),
    accentHover = Color3.fromRGB(108, 210, 164),
    onAccent = Color3.fromRGB(14, 30, 24),
    warn = Color3.fromRGB(235, 176, 80),
    bad = Color3.fromRGB(226, 98, 98),
    badHover = Color3.fromRGB(238, 120, 120),
}

local F = {
    reg = Enum.Font.BuilderSans,
    med = Enum.Font.BuilderSansMedium,
    bold = Enum.Font.BuilderSansBold,
}

local function make(className, props, parent)
    local o = Instance.new(className)
    for k, v in pairs(props) do
        o[k] = v
    end
    if parent then
        o.Parent = parent
    end
    return o
end

local function corner(parent, radius)
    return make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function stroke(parent, color, thickness, name)
    return make("UIStroke", {
        Color = color,
        Thickness = thickness,
        Name = name or "UIStroke",
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
end

local function text(parent, props)
    local p = {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Font = F.reg,
        TextSize = 13,
        TextColor3 = C.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    }
    for k, v in pairs(props) do
        p[k] = v
    end
    return make("TextLabel", p, parent)
end

local function button(parent, props)
    local base = props.Bg or C.panel2
    local b = make("TextButton", {
        Name = props.Name or "Button",
        Size = props.Size,
        Position = props.Position or UDim2.new(),
        BackgroundColor3 = base,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = props.Text or "",
        Font = props.Font or F.med,
        TextSize = props.TextSize or 13,
        TextColor3 = props.TextColor or C.text,
    }, parent)
    corner(b, props.Radius or 6)
    b:SetAttribute("Base", base)
    b:SetAttribute("Hover", props.Hover or C.line)
    b:SetAttribute("BaseText", props.TextColor or C.text)
    b:SetAttribute("Disabled", false)
    track(b.MouseEnter:Connect(function()
        if not b:GetAttribute("Disabled") then
            b.BackgroundColor3 = b:GetAttribute("Hover")
        end
    end))
    track(b.MouseLeave:Connect(function()
        if not b:GetAttribute("Disabled") then
            b.BackgroundColor3 = b:GetAttribute("Base")
        end
    end))
    return b
end

local function setDisabled(b, disabled)
    b:SetAttribute("Disabled", disabled)
    b.BackgroundColor3 = disabled and C.panel or b:GetAttribute("Base")
    b.TextColor3 = disabled and C.dim or b:GetAttribute("BaseText")
end

local function onClick(b, fn)
    track(b.Activated:Connect(function()
        if b:GetAttribute("Disabled") then return end
        fn()
    end))
end

--------------------------------------------------------------------
-- AVATAR DATA
--------------------------------------------------------------------
local R15_PARTS = {
    "Head", "UpperTorso", "LowerTorso",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
}

local R6_PARTS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local REPLACE_ORDER = {
    "LowerTorso", "UpperTorso", "Head",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
}

-- scale key -> NumberValue name inside the Humanoid
local SCALE_VALUE_NAMES = {
    Height = "BodyHeightScale",
    Width = "BodyWidthScale",
    Depth = "BodyDepthScale",
    Head = "HeadScale",
    BodyType = "BodyTypeScale",
    Proportion = "BodyProportionScale",
}

local SCALE_DEFAULTS = { Height = 1, Width = 1, Depth = 1, Head = 1, BodyType = 0, Proportion = 0 }
local OwnScalesByChar = setmetatable({}, { __mode = "k" })

-- Your own scales, remembered BEFORE the character is modified
local function getOwnScales(char)
    if char and OwnScalesByChar[char] then
        return OwnScalesByChar[char]
    end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local s = {}
    for key, valueName in pairs(SCALE_VALUE_NAMES) do
        local v = hum and hum:FindFirstChild(valueName)
        if v and v:IsA("NumberValue") then
            s[key] = v.Value
        else
            s[key] = SCALE_DEFAULTS[key]
        end
    end
    if char then
        OwnScalesByChar[char] = s
    end
    return s
end

local function scalesKey(s)
    return string.format("%.3f_%.3f_%.3f_%.3f_%.3f_%.3f",
        s.Height, s.Width, s.Depth, s.Head, s.BodyType, s.Proportion)
end

local descriptionFromAppearance
do
-- Fallback for banned/deleted accounts: build a HumanoidDescription from AppearanceInfo
local BODY_ASSET_FIELDS = {
    Face = "Face", Head = "Head", DynamicHead = "Head", Torso = "Torso",
    RightArm = "RightArm", LeftArm = "LeftArm", RightLeg = "RightLeg", LeftLeg = "LeftLeg",
    TShirt = "GraphicTShirt", Shirt = "Shirt", Pants = "Pants",
}
local ACCESSORY_TYPE_MAP = {
    Hat = "Hat", HatAccessory = "Hat", HairAccessory = "Hair", FaceAccessory = "Face",
    NeckAccessory = "Neck", ShoulderAccessory = "Shoulder", FrontAccessory = "Front",
    BackAccessory = "Back", WaistAccessory = "Waist", TShirtAccessory = "TShirt",
    ShirtAccessory = "Shirt", PantsAccessory = "Pants", JacketAccessory = "Jacket",
    SweaterAccessory = "Sweater", ShortsAccessory = "Shorts", LeftShoeAccessory = "LeftShoe",
    RightShoeAccessory = "RightShoe", DressSkirtAccessory = "DressSkirt",
}
local LAYERED_TYPES = {
    TShirt = true, Shirt = true, Pants = true, Jacket = true, Sweater = true,
    Shorts = true, LeftShoe = true, RightShoe = true, DressSkirt = true,
}

function descriptionFromAppearance(info)
    if type(info) ~= "table" or type(info.assets) ~= "table" then
        return nil
    end
    local desc = Instance.new("HumanoidDescription")
    local accessories = {}
    for _, a in ipairs(info.assets) do
        local tname = a.assetType and a.assetType.name
        local field = tname and BODY_ASSET_FIELDS[tname]
        if field then
            pcall(function() desc[field] = a.id end)
        elseif tname and ACCESSORY_TYPE_MAP[tname] then
            local at = ACCESSORY_TYPE_MAP[tname]
            local okE, enumItem = pcall(function() return Enum.AccessoryType[at] end)
            if okE and enumItem then
                table.insert(accessories, {
                    Order = #accessories + 1,
                    AssetId = a.id,
                    AccessoryType = enumItem,
                    IsLayered = LAYERED_TYPES[at] == true,
                })
            end
        end
    end
    pcall(function() desc:SetAccessories(accessories, true) end)

    local bc = info.bodyColors
    if type(bc) == "table" then
        local map = {
            HeadColor = "headColorId", TorsoColor = "torsoColorId",
            LeftArmColor = "leftArmColorId", RightArmColor = "rightArmColorId",
            LeftLegColor = "leftLegColorId", RightLegColor = "rightLegColorId",
        }
        for prop, key in pairs(map) do
            if bc[key] then
                pcall(function() desc[prop] = BrickColor.new(bc[key]).Color end)
            end
        end
    end

    local sc = info.scales
    if type(sc) == "table" then
        pcall(function()
            if sc.height then desc.HeightScale = sc.height end
            if sc.width then desc.WidthScale = sc.width end
            if sc.depth then desc.DepthScale = sc.depth end
            if sc.head then desc.HeadScale = sc.head end
            if sc.proportion then desc.ProportionScale = sc.proportion end
            if sc.bodyType then desc.BodyTypeScale = sc.bodyType end
        end)
    end
    return desc
end

end

local function prepareTemplate(model)
    model.Archivable = true
    for _, d in ipairs(model:GetDescendants()) do
        pcall(function() d.Archivable = true end)
        if d:IsA("BaseScript") then
            d:Destroy()
        end
    end
end

local function summarizeAppearance(info)
    local s = { HeadAssetId = nil, HeadAssetTypeName = nil, FaceAssetId = nil, PlayerAvatarType = nil }
    if type(info) ~= "table" then
        return s
    end
    s.PlayerAvatarType = info.playerAvatarType
    if type(info.assets) == "table" then
        for _, a in ipairs(info.assets) do
            local tname = a.assetType and a.assetType.name
            if tname == "DynamicHead" or tname == "Head" then
                s.HeadAssetId = a.id
                s.HeadAssetTypeName = tname
            elseif tname == "Face" then
                s.FaceAssetId = a.id
            end
        end
    end
    return s
end

local function buildAvatarData(userData, rigName, ownScales)
    local userId = userData.Id
    local wantRig = (rigName == "R6") and Enum.HumanoidRigType.R6 or Enum.HumanoidRigType.R15
    local keepOwnShape = (not Settings.CopyShape) and ownScales ~= nil

    local appearanceInfo
    pcall(function()
        appearanceInfo = Players:GetCharacterAppearanceInfoAsync(userId)
    end)

    local desc, fromFallback
    local okDesc, d = pcall(function()
        return Players:GetHumanoidDescriptionFromUserId(userId)
    end)
    if okDesc and d then
        desc = d
    else
        desc = descriptionFromAppearance(appearanceInfo)
        fromFallback = desc ~= nil
        if fromFallback then
            log("description built from AppearanceInfo (fallback) for", userId)
        end
    end
    if not desc then
        return nil, "Roblox returned no avatar data for this account"
    end

    -- Shape copying off: target's looks, your own proportions
    if keepOwnShape then
        desc = desc:Clone()
        pcall(function()
            desc.HeightScale = ownScales.Height
            desc.WidthScale = ownScales.Width
            desc.DepthScale = ownScales.Depth
            desc.HeadScale = ownScales.Head
            desc.BodyTypeScale = ownScales.BodyType
            desc.ProportionScale = ownScales.Proportion
        end)
    end

    -- The target model is always built for YOUR rig type (R6/R15)
    local template
    if not keepOwnShape and not fromFallback then
        pcall(function()
            template = Players:CreateHumanoidModelFromUserIdAsync(userId)
        end)
        if template then
            local th = template:FindFirstChildOfClass("Humanoid")
            if not th or th.RigType ~= wantRig then
                template:Destroy()
                template = nil
            end
        end
    end
    if not template then
        pcall(function()
            template = Players:CreateHumanoidModelFromDescription(desc, wantRig)
        end)
    end
    if not template then
        return nil, "Could not build avatar model"
    end

    -- Second source: if the model has no looks but the description does, rebuild from it
    do
        local function hasLooks(m)
            for _, c in ipairs(m:GetChildren()) do
                if c:IsA("Accessory") or c:IsA("Shirt") or c:IsA("Pants") or c:IsA("ShirtGraphic") then
                    return true
                end
            end
            return false
        end
        local descHasLooks = (desc.Shirt or 0) ~= 0 or (desc.Pants or 0) ~= 0 or (desc.GraphicTShirt or 0) ~= 0
        pcall(function()
            if #desc:GetAccessories(true) > 0 then
                descHasLooks = true
            end
        end)
        if descHasLooks and not hasLooks(template) then
            local alt
            pcall(function()
                alt = Players:CreateHumanoidModelFromDescription(desc, wantRig)
            end)
            if alt and hasLooks(alt) then
                template:Destroy()
                template = alt
                log("template rebuilt from description (second source)")
            elseif alt then
                alt:Destroy()
            end
        end
    end

    prepareTemplate(template)
    template.Name = "AvatarTemplate"

    local tHum = template:FindFirstChildOfClass("Humanoid")
    if not tHum then
        template:Destroy()
        return nil, "Avatar model has no Humanoid"
    end

    local rig = (tHum.RigType == Enum.HumanoidRigType.R15) and "R15" or "R6"
    local appearance = summarizeAppearance(appearanceInfo)

    local descScales = {
        Height = desc.HeightScale, Width = desc.WidthScale, Depth = desc.DepthScale,
        Head = desc.HeadScale, BodyType = desc.BodyTypeScale, Proportion = desc.ProportionScale,
    }
    local scales = {}
    for key, valueName in pairs(SCALE_VALUE_NAMES) do
        local v = tHum:FindFirstChild(valueName)
        if v and v:IsA("NumberValue") then
            scales[key] = v.Value
        else
            scales[key] = descScales[key]
        end
    end

    local bodyParts = {}
    for _, name in ipairs(rig == "R15" and R15_PARTS or R6_PARTS) do
        local p = template:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            bodyParts[name] = p
        end
    end

    local tHead = template:FindFirstChild("Head")
    local head = {
        AssetId = desc.Head,
        FaceId = desc.Face,
        AppearanceHeadAssetId = appearance.HeadAssetId,
        AppearanceHeadAssetType = appearance.HeadAssetTypeName,
        IsMeshPart = tHead ~= nil and tHead:IsA("MeshPart"),
        HasFaceControls = tHead ~= nil and tHead:FindFirstChildOfClass("FaceControls") ~= nil,
        HasSurfaceAppearance = tHead ~= nil and tHead:FindFirstChildOfClass("SurfaceAppearance") ~= nil,
        MeshId = "",
        TextureId = "",
    }
    if tHead then
        if tHead:IsA("MeshPart") then
            head.MeshId = tHead.MeshId
            head.TextureId = tHead.TextureID
        else
            local sm = tHead:FindFirstChildOfClass("SpecialMesh")
            if sm then
                head.MeshId = sm.MeshId
                head.TextureId = sm.TextureId
            end
        end
    end
    head.IsDynamic = head.HasFaceControls
    head.IsSpecial = (desc.Head ~= 0) or (appearance.HeadAssetId ~= nil and appearance.HeadAssetId ~= 0)

    local faceDecal = tHead and tHead:FindFirstChild("face")
    local face = {
        AssetId = desc.Face,
        DecalTexture = (faceDecal and faceDecal:IsA("Decal")) and faceDecal.Texture or nil,
        HasFaceControls = head.HasFaceControls,
    }

    local tbc = template:FindFirstChildOfClass("BodyColors")
    local bodyColors = {
        HeadColor3 = tbc and tbc.HeadColor3 or desc.HeadColor,
        TorsoColor3 = tbc and tbc.TorsoColor3 or desc.TorsoColor,
        LeftArmColor3 = tbc and tbc.LeftArmColor3 or desc.LeftArmColor,
        RightArmColor3 = tbc and tbc.RightArmColor3 or desc.RightArmColor,
        LeftLegColor3 = tbc and tbc.LeftLegColor3 or desc.LeftLegColor,
        RightLegColor3 = tbc and tbc.RightLegColor3 or desc.RightLegColor,
    }

    local layered = {}
    pcall(function()
        for _, a in ipairs(desc:GetAccessories(true)) do
            if a.IsLayered then
                table.insert(layered, a)
            end
        end
    end)

    local accessories = {}
    for _, item in ipairs(template:GetChildren()) do
        if item:IsA("Accessory") then
            table.insert(accessories, item)
        end
    end

    local data = {
        UserId = userId,
        Username = userData.Username,
        DisplayName = userData.DisplayName,
        Rig = rig,
        Description = desc,
        Template = template,
        TemplateHumanoid = tHum,
        Body = bodyParts,
        BodyColors = bodyColors,
        Scales = scales,
        Head = head,
        Face = face,
        LayeredClothing = layered,
        Accessories = accessories,
        FromFallback = fromFallback == true,
        KeepOwnShape = keepOwnShape,
        IsNpc = false,
        PreviewMaster = nil, -- built lazily by the 3D preview
    }

    log("DATA", userData.Username, "rig=" .. rig, "headAsset=" .. tostring(head.AssetId),
        "dynamic=" .. tostring(head.IsDynamic), "layered=" .. #layered,
        "accessories=" .. #accessories, "fallback=" .. tostring(fromFallback == true))

    return data
end

--------------------------------------------------------------------
-- NPC DATA
-- An NPC is any Model with a Humanoid that does not belong to a player.
-- Its look is read straight from the model: the model is cloned (protected
-- NPCs are unlocked for the clone only), and the clone becomes the template.
--------------------------------------------------------------------
local buildNpcData
do
local function cloneNpcModel(model)
    local restore = {}
    local function unlock(inst)
        local ok, arch = pcall(function() return inst.Archivable end)
        if ok and arch == false then
            pcall(function() inst.Archivable = true end)
            table.insert(restore, inst)
        end
    end
    unlock(model)
    for _, d in ipairs(model:GetDescendants()) do
        unlock(d)
    end
    local ok, clone = pcall(function() return model:Clone() end)
    for _, inst in ipairs(restore) do
        pcall(function() inst.Archivable = false end)
    end
    if ok and clone then
        return clone
    end
    return nil
end

local function colorsFromParts(model)
    local fallback = Color3.fromRGB(163, 162, 165)
    local function pick(names)
        for _, n in ipairs(names) do
            local p = model:FindFirstChild(n)
            if p and p:IsA("BasePart") then
                return p.Color
            end
        end
        return fallback
    end
    return {
        HeadColor3 = pick({ "Head" }),
        TorsoColor3 = pick({ "UpperTorso", "Torso" }),
        LeftArmColor3 = pick({ "LeftUpperArm", "Left Arm" }),
        RightArmColor3 = pick({ "RightUpperArm", "Right Arm" }),
        LeftLegColor3 = pick({ "LeftUpperLeg", "Left Leg" }),
        RightLegColor3 = pick({ "RightUpperLeg", "Right Leg" }),
    }
end

function buildNpcData(userData)
    local model = userData.Model
    if not model or not model.Parent then
        return nil, "This NPC no longer exists"
    end

    local template = cloneNpcModel(model)
    if not template then
        return nil, "Could not copy this NPC (protected model)"
    end
    prepareTemplate(template)
    template.Name = "AvatarTemplate"
    -- NPCs are often anchored; the template must be free so copied accessories never freeze
    for _, d in ipairs(template:GetDescendants()) do
        if d:IsA("BasePart") then
            d.Anchored = false
        end
    end

    local tHum = template:FindFirstChildOfClass("Humanoid")
    if not tHum then
        template:Destroy()
        return nil, "NPC has no Humanoid"
    end

    local rig = (tHum.RigType == Enum.HumanoidRigType.R15) and "R15" or "R6"
    local desc = Instance.new("HumanoidDescription") -- placeholder, NPC data comes from the model

    local scales = {}
    for key, valueName in pairs(SCALE_VALUE_NAMES) do
        local v = tHum:FindFirstChild(valueName)
        if v and v:IsA("NumberValue") then
            scales[key] = v.Value
        else
            scales[key] = SCALE_DEFAULTS[key]
        end
    end

    local bodyParts = {}
    for _, name in ipairs(rig == "R15" and R15_PARTS or R6_PARTS) do
        local p = template:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            bodyParts[name] = p
        end
    end

    local tHead = template:FindFirstChild("Head")
    local head = {
        AssetId = 0,
        FaceId = 0,
        AppearanceHeadAssetId = nil,
        AppearanceHeadAssetType = nil,
        IsMeshPart = tHead ~= nil and tHead:IsA("MeshPart"),
        HasFaceControls = tHead ~= nil and tHead:FindFirstChildOfClass("FaceControls") ~= nil,
        HasSurfaceAppearance = tHead ~= nil and tHead:FindFirstChildOfClass("SurfaceAppearance") ~= nil,
        MeshId = "",
        TextureId = "",
    }
    if tHead then
        if tHead:IsA("MeshPart") then
            head.MeshId = tHead.MeshId
            head.TextureId = tHead.TextureID
        else
            local sm = tHead:FindFirstChildOfClass("SpecialMesh")
            if sm then
                head.MeshId = sm.MeshId
                head.TextureId = sm.TextureId
            end
        end
    end
    head.IsDynamic = head.HasFaceControls
    head.IsSpecial = head.IsMeshPart and not head.IsDynamic

    local faceDecal = tHead and tHead:FindFirstChild("face")
    local face = {
        AssetId = 0,
        DecalTexture = (faceDecal and faceDecal:IsA("Decal")) and faceDecal.Texture or nil,
        HasFaceControls = head.HasFaceControls,
    }

    local tbc = template:FindFirstChildOfClass("BodyColors")
    local bodyColors
    if tbc then
        bodyColors = {
            HeadColor3 = tbc.HeadColor3, TorsoColor3 = tbc.TorsoColor3,
            LeftArmColor3 = tbc.LeftArmColor3, RightArmColor3 = tbc.RightArmColor3,
            LeftLegColor3 = tbc.LeftLegColor3, RightLegColor3 = tbc.RightLegColor3,
        }
    else
        bodyColors = colorsFromParts(template)
    end

    local accessories, layered = {}, {}
    for _, item in ipairs(template:GetChildren()) do
        if item:IsA("Accessory") then
            table.insert(accessories, item)
            local h = item:FindFirstChild("Handle")
            if h and h:FindFirstChildWhichIsA("WrapLayer") then
                table.insert(layered, item)
            end
        end
    end

    local partCount = 0
    for _ in pairs(bodyParts) do
        partCount += 1
    end
    log("NPC DATA", userData.Username, "rig=" .. rig, "parts=" .. partCount,
        "accessories=" .. #accessories)

    return {
        UserId = userData.Id,
        Username = userData.Username,
        DisplayName = userData.DisplayName,
        Rig = rig,
        Description = desc,
        Template = template,
        TemplateHumanoid = tHum,
        Body = bodyParts,
        BodyColors = bodyColors,
        Scales = scales,
        Head = head,
        Face = face,
        LayeredClothing = layered,
        Accessories = accessories,
        FromFallback = false,
        KeepOwnShape = false,
        IsNpc = true,
        HasBodyColors = tbc ~= nil,
        PreviewMaster = nil,
    }
end

end

local function localRigName()
    local char = localPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.RigType == Enum.HumanoidRigType.R6 then
        return "R6"
    end
    return "R15"
end

local function GetAvatarData(userData, rigName, ownScales)
    local key, builder
    if userData.IsNpc then
        key = "npc:" .. tostring(userData.Id)
        builder = function()
            return buildNpcData(userData)
        end
    else
        rigName = rigName or localRigName()
        ownScales = ownScales or getOwnScales(localPlayer.Character)
        local shapeTag = Settings.CopyShape and "shape" or ("own" .. scalesKey(ownScales))
        key = tostring(userData.Id) .. ":" .. rigName .. ":" .. shapeTag
        builder = function()
            return buildAvatarData(userData, rigName, ownScales)
        end
    end

    if DataCache[key] then
        return DataCache[key]
    end
    if DataLoading[key] then
        local waited = 0
        while DataLoading[key] and waited < 20 do
            task.wait(0.05)
            waited += 0.05
        end
        return DataCache[key], (DataCache[key] == nil) and "Avatar data failed to load" or nil
    end

    DataLoading[key] = true
    local ok, data, err = pcall(builder)
    DataLoading[key] = nil

    if not ok then
        return nil, tostring(data)
    end
    if data then
        DataCache[key] = data
    end
    return data, err
end

-- An NPC can change its outfit: drop the cached copy so the next copy sees the current look
local function refreshNpcCache(userData)
    if not (userData and userData.IsNpc and userData.Model and userData.Model.Parent) then return end
    local key = "npc:" .. tostring(userData.Id)
    local old = DataCache[key]
    if old then
        DataCache[key] = nil
        if old.Template then pcall(function() old.Template:Destroy() end) end
        if old.PreviewMaster then pcall(function() old.PreviewMaster:Destroy() end) end
    end
end

--------------------------------------------------------------------
-- SHAPE ENGINE
-- A "shape target" describes a body: part templates, joint offsets, root size,
-- hip height and scales. It is built from a target avatar (copy) or from the
-- snapshot of your original character (restore).
--------------------------------------------------------------------
local function sizeClose(a, b)
    return math.abs(a.X - b.X) <= 0.03 + 0.02 * b.X
        and math.abs(a.Y - b.Y) <= 0.03 + 0.02 * b.Y
        and math.abs(a.Z - b.Z) <= 0.03 + 0.02 * b.Z
end

local function cfNear(a, b)
    return (a.Position - b.Position).Magnitude < 0.002
        and a.LookVector:Dot(b.LookVector) > 0.99995
        and a.UpVector:Dot(b.UpVector) > 0.99995
end

-- Calls fn(motor) for every Motor6D that sits directly inside a body part of the model
local function eachJoint(model, fn)
    for _, part in ipairs(model:GetChildren()) do
        if part:IsA("BasePart") then
            for _, j in ipairs(part:GetChildren()) do
                if j:IsA("Motor6D") then
                    fn(j)
                end
            end
        end
    end
end

local function jointKey(j)
    return j.Name .. "|" .. (j.Part1 and j.Part1.Name or "")
end

local function collectJoints(model)
    local out = {}
    eachJoint(model, function(j)
        if j.Part0 and j.Part1 then
            out[jointKey(j)] = { C0 = j.C0, C1 = j.C1 }
        end
    end)
    return out
end

-- Rest-pose hip height computed from joint offsets and part sizes (R15)
local function restHip(joints, sizes)
    local rootSize = sizes.HumanoidRootPart
    if not rootSize then return nil end
    local best
    for _, side in ipairs({ "Left", "Right" }) do
        local chain = {
            { "Root", "LowerTorso" },
            { side .. "Hip", side .. "UpperLeg" },
            { side .. "Knee", side .. "LowerLeg" },
            { side .. "Ankle", side .. "Foot" },
        }
        local cf = CFrame.new()
        local ok = true
        for _, step in ipairs(chain) do
            local j = joints[step[1] .. "|" .. step[2]]
            if not j then
                ok = false
                break
            end
            cf = cf * j.C0 * j.C1:Inverse()
        end
        local fs = sizes[side .. "Foot"]
        if ok and fs then
            local r = { cf:GetComponents() }
            local ey = (math.abs(r[7]) * fs.X + math.abs(r[8]) * fs.Y + math.abs(r[9]) * fs.Z) / 2
            local footBottom = cf.Y - ey
            local hip = -rootSize.Y / 2 - footBottom
            if not best or hip > best then
                best = hip
            end
        end
    end
    if best and best == best and best > -50 and best < 50 then
        return best
    end
    return nil
end

local function sizesOf(bodyParts, rootSize)
    local sizes = { HumanoidRootPart = rootSize }
    for name, p in pairs(bodyParts) do
        sizes[name] = p.Size
    end
    return sizes
end

local function buildShapeTarget(data, hipCalib)
    local target = {
        Body = data.Body,
        Scales = data.Scales,
        Joints = collectJoints(data.Template),
    }
    local root = data.Template:FindFirstChild("HumanoidRootPart")
    target.RootSize = root and root.Size
    local hip = data.TemplateHumanoid and data.TemplateHumanoid.HipHeight or 2
    if data.Rig == "R15" and hipCalib and target.RootSize then
        local geom = restHip(target.Joints, sizesOf(data.Body, target.RootSize))
        if geom then
            local calibrated = geom + hipCalib
            if calibrated > 0.05 and calibrated < 60 then
                log(("hip height: template=%.3f calibrated=%.3f"):format(hip, calibrated))
                hip = calibrated
            end
        end
    end
    target.HipHeight = hip
    return target
end

-- Re-weld accessories whose weld still points at a destroyed body part
local function weldAccessoryManually(char, acc)
    local handle = acc:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then return false end
    for _, w in ipairs(handle:GetChildren()) do
        if w:IsA("JointInstance") and w.Part0 and w.Part1 then
            return true
        end
    end
    for _, att in ipairs(handle:GetChildren()) do
        if att:IsA("Attachment") then
            for _, part in ipairs(char:GetChildren()) do
                if part:IsA("BasePart") then
                    local cAtt = part:FindFirstChild(att.Name)
                    if cAtt and cAtt:IsA("Attachment") then
                        local w = Instance.new("Weld")
                        w.Name = "AccessoryWeld"
                        w.Part0 = part
                        w.Part1 = handle
                        w.C0 = cAtt.CFrame
                        w.C1 = att.CFrame
                        w.Parent = handle
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function reattachAccessories(char)
    for _, acc in ipairs(char:GetChildren()) do
        if acc:IsA("Accessory") then
            local handle = acc:FindFirstChild("Handle")
            if handle and handle:IsA("BasePart") then
                local good = false
                for _, w in ipairs(handle:GetChildren()) do
                    if w:IsA("JointInstance") then
                        if w.Part0 and w.Part1 and w.Part0:IsDescendantOf(char) and w.Part1:IsDescendantOf(char) then
                            good = true
                        else
                            w:Destroy()
                        end
                    end
                end
                if not good then
                    weldAccessoryManually(char, acc)
                end
            end
        end
    end
end

-- Last resort when Humanoid:ReplaceBodyPartR15 refuses a part: swap it by hand
local function manualReplacePart(char, name, tPart, target)
    local old = char:FindFirstChild(name)
    if not old or not old:IsA("BasePart") then return false end

    local new = tPart:Clone()
    for _, ch in ipairs(new:GetChildren()) do
        if ch:IsA("Motor6D") then
            ch:Destroy()
        end
    end
    new.Anchored = false
    new.CFrame = old.CFrame

    local motors = {}
    eachJoint(char, function(j)
        if j.Part0 == old or j.Part1 == old then
            table.insert(motors, j)
        end
    end)
    for _, j in ipairs(old:GetChildren()) do
        if j:IsA("Motor6D") then
            local dup = false
            for _, m in ipairs(motors) do
                if m == j then dup = true break end
            end
            if not dup then
                table.insert(motors, j)
            end
        end
    end

    old.Name = name .. "_old"
    new.Parent = char
    for _, j in ipairs(motors) do
        if j.Part0 == old then j.Part0 = new end
        if j.Part1 == old then j.Part1 = new end
        if j.Parent == old then j.Parent = new end
        local tj = target.Joints[jointKey(j)]
        if tj then
            j.C0 = tj.C0
            j.C1 = tj.C1
        end
    end
    old:Destroy()
    return true
end

local function replacePart(char, hum, name, tPart, target)
    local newPart = tPart:Clone()
    for _, ch in ipairs(newPart:GetChildren()) do
        if ch:IsA("Motor6D") then
            ch:Destroy() -- the Humanoid rebuilds joints from RigAttachments
        end
    end
    newPart.Anchored = false
    local ok, res = pcall(function()
        return hum:ReplaceBodyPartR15(Enum.BodyPartR15[name], newPart)
    end)
    if ok and res ~= false then
        return true
    end
    pcall(function() newPart:Destroy() end)
    log("[SHAPE] engine replace failed for", name, "- trying manual swap")
    return manualReplacePart(char, name, tPart, target)
end

local function syncJoints(char, target)
    local changed = false
    eachJoint(char, function(j)
        local tj = target.Joints[jointKey(j)]
        if tj then
            if not cfNear(j.C0, tj.C0) then
                pcall(function() j.C0 = tj.C0 end)
                changed = true
            end
            if not cfNear(j.C1, tj.C1) then
                pcall(function() j.C1 = tj.C1 end)
                changed = true
            end
        end
    end)
    return changed
end

-- Brings the character to the target shape. Returns the number of replaced parts.
local function enforceShape(char, hum, target, attempts)
    if hum.AutomaticScalingEnabled then
        pcall(function() hum.AutomaticScalingEnabled = false end)
    end

    for key, valueName in pairs(SCALE_VALUE_NAMES) do
        local want = target.Scales[key]
        local v = hum:FindFirstChild(valueName)
        if want and v and v:IsA("NumberValue") and math.abs(v.Value - want) > 0.001 then
            v.Value = want
        end
    end

    local changed = 0
    for _, name in ipairs(REPLACE_ORDER) do
        local tPart = target.Body[name]
        if tPart then
            local cPart = char:FindFirstChild(name)
            local isPart = cPart ~= nil and cPart:IsA("BasePart")
            if not isPart or not sizeClose(cPart.Size, tPart.Size) then
                attempts[name] = (attempts[name] or 0) + 1
                if attempts[name] <= 3 then
                    if replacePart(char, hum, name, tPart, target) then
                        changed += 1
                    end
                elseif isPart then
                    pcall(function() cPart.Size = tPart.Size end)
                end
            end
        end
    end

    local root = char:FindFirstChild("HumanoidRootPart")
    if root and target.RootSize and not sizeClose(root.Size, target.RootSize) then
        pcall(function() root.Size = target.RootSize end)
    end

    syncJoints(char, target)

    if target.HipHeight and math.abs(hum.HipHeight - target.HipHeight) > 0.05 then
        pcall(function() hum.HipHeight = target.HipHeight end)
    end

    if changed > 0 then
        reattachAccessories(char)
    end
    return changed
end

--------------------------------------------------------------------
-- ORIGINAL SNAPSHOT (so the real avatar can always be restored)
--------------------------------------------------------------------
local Original = nil

local function isLook(ch)
    return ch:IsA("Accessory") or ch:IsA("Shirt") or ch:IsA("Pants") or ch:IsA("ShirtGraphic")
        or ch:IsA("CharacterMesh") or ch:IsA("BodyColors")
end

local function destroySnapshot(snap)
    if not snap then return end
    for _, p in pairs(snap.parts) do
        pcall(function() p:Destroy() end)
    end
    for _, l in ipairs(snap.looks) do
        pcall(function() l:Destroy() end)
    end
end

local function captureOriginal(char, hum)
    if Original and Original.char == char then
        return Original
    end
    destroySnapshot(Original)

    local snap = {
        char = char,
        rig = hum.RigType,
        parts = {},
        looks = {},
        scales = {},
        autoScaling = hum.AutomaticScalingEnabled,
        hipHeight = hum.HipHeight,
        modified = false,
    }

    for key, valueName in pairs(SCALE_VALUE_NAMES) do
        local v = hum:FindFirstChild(valueName)
        if v and v:IsA("NumberValue") then
            snap.scales[key] = v.Value
        end
    end

    if hum.RigType == Enum.HumanoidRigType.R15 then
        for _, name in ipairs(R15_PARTS) do
            local p = char:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                local ok, c = pcall(function() return p:Clone() end)
                if ok and c then
                    for _, ch in ipairs(c:GetChildren()) do
                        if ch:IsA("Motor6D") then
                            ch:Destroy()
                        end
                    end
                    snap.parts[name] = c
                end
            end
        end
    else
        local head = char:FindFirstChild("Head")
        if head then
            local sm = head:FindFirstChildOfClass("SpecialMesh")
            local face = head:FindFirstChild("face")
            snap.r6Head = {
                hadMesh = sm ~= nil,
                meshType = sm and sm.MeshType,
                meshId = sm and sm.MeshId,
                textureId = sm and sm.TextureId,
                scale = sm and sm.Scale,
                offset = sm and sm.Offset,
                hadFace = face ~= nil and face:IsA("Decal"),
                faceTexture = (face and face:IsA("Decal")) and face.Texture or nil,
            }
        end
        -- R6 part colors (needed when an NPC without BodyColors was copied)
        snap.r6Colors = {}
        for _, name in ipairs(R6_PARTS) do
            local p = char:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                snap.r6Colors[name] = p.Color
            end
        end
    end

    for _, ch in ipairs(char:GetChildren()) do
        if isLook(ch) then
            local ok, c = pcall(function() return ch:Clone() end)
            if ok and c then
                table.insert(snap.looks, c)
            end
        end
    end

    local root = char:FindFirstChild("HumanoidRootPart")
    snap.target = {
        Body = snap.parts,
        Scales = snap.scales,
        Joints = collectJoints(char),
        RootSize = root and root.Size,
        HipHeight = hum.HipHeight,
    }

    -- Hip height calibration: engine value minus geometric value of YOUR rig
    if hum.RigType == Enum.HumanoidRigType.R15 and snap.target.RootSize then
        local geom = restHip(snap.target.Joints, sizesOf(snap.parts, snap.target.RootSize))
        if geom then
            snap.hipCalib = hum.HipHeight - geom
        end
    end

    Original = snap
    log("original avatar snapshot captured")
    return snap
end

--------------------------------------------------------------------
-- REAL AVATAR (you become the avatar; animations are left to the game)
--------------------------------------------------------------------
local RealAvatar = {
    active = false,
    char = nil,
    conns = {},
    token = 0,
}

local function applyLooks(char, hum, data)
    local stats = { clothing = 0, accessories = 0, failed = 0 }

    for _, ch in ipairs(data.Template:GetChildren()) do
        if ch:IsA("Shirt") or ch:IsA("Pants") or ch:IsA("ShirtGraphic") or ch:IsA("CharacterMesh") then
            local ok, c = pcall(function() return ch:Clone() end)
            if ok and c then
                c.Parent = char
                stats.clothing += 1
            else
                stats.failed += 1
            end
        end
    end

    local added = {}
    for _, acc in ipairs(data.Accessories) do
        local ok, c = pcall(function() return acc:Clone() end)
        if ok and c then
            local handle = c:FindFirstChild("Handle")
            if handle then
                handle.Anchored = false
                for _, w in ipairs(handle:GetChildren()) do
                    if w:IsA("JointInstance") or w:IsA("WeldConstraint") then
                        w:Destroy()
                    end
                end
            end
            local okA = pcall(function() hum:AddAccessory(c) end)
            if not okA or not c.Parent then
                c.Parent = char
            end
            table.insert(added, c)
        else
            stats.failed += 1
        end
    end

    task.wait(0.2)
    for _, c in ipairs(added) do
        if c.Parent == char and weldAccessoryManually(char, c) then
            stats.accessories += 1
        else
            stats.failed += 1
        end
    end

    log(("[LOOKS] clothing=%d accessories=%d/%d failed=%d"):format(
        stats.clothing, stats.accessories, #data.Accessories, stats.failed))
    return stats
end

function RealAvatar:Clear()
    self.token += 1
    for _, c in ipairs(self.conns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(self.conns)
    self.active = false
    self.char = nil
end

local function isBodyGrip(j, handle, tool)
    if not j:IsA("JointInstance") or j:IsA("Motor6D") then return false end
    if j.Part1 == handle then
        return j.Part0 == nil or not j.Part0:IsDescendantOf(tool)
    end
    if j.Part0 == handle then
        return j.Part1 == nil or not j.Part1:IsDescendantOf(tool)
    end
    return false
end

-- R15: weld the tool handle to the NEW right hand, like the default RightGrip
function RealAvatar:AttachTool(char, tool)
    local hand = char:FindFirstChild("RightHand")
    local handle = tool:FindFirstChild("Handle")
    if not hand or not handle or not handle:IsA("BasePart") then return end

    local grip = hand:FindFirstChild("RightGrip")
    if grip and grip:IsA("Weld") and grip.Part0 == hand and grip.Part1 == handle then
        return
    end

    for _, d in ipairs(char:GetDescendants()) do
        if d ~= grip and isBodyGrip(d, handle, tool) then
            d:Destroy()
        end
    end
    if grip then grip:Destroy() end

    grip = Instance.new("Weld")
    grip.Name = "RightGrip"
    grip.Part0 = hand
    grip.Part1 = handle
    local att = hand:FindFirstChild("RightGripAttachment")
    grip.C0 = att and att.CFrame or CFrame.new()
    grip.C1 = tool.Grip
    grip.Parent = hand
end

function RealAvatar:WatchTool(char, tool)
    local token = self.token
    task.spawn(function()
        task.wait(0.1)
        while self.active and self.token == token and tool.Parent == char and char.Parent do
            pcall(function() self:AttachTool(char, tool) end)
            task.wait(0.35)
        end
        local hand = char:FindFirstChild("RightHand")
        local g = hand and hand:FindFirstChild("RightGrip")
        if g and (g.Part1 == nil or g.Part1:IsDescendantOf(tool)) and tool.Parent ~= char then
            g:Destroy()
        end
    end)
end

-- Players: copy the template's BodyColors.
-- NPCs without BodyColors: remove ours so the copied parts keep their own colors,
-- and paint same-named parts (R6) with the NPC's part colors.
local function setBodyColors(char, source)
    local tbc = source:FindFirstChildOfClass("BodyColors")
    local old = char:FindFirstChildOfClass("BodyColors")
    if tbc then
        if old then old:Destroy() end
        tbc:Clone().Parent = char
    else
        if old then old:Destroy() end
        for _, p in ipairs(source:GetChildren()) do
            if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                local cp = char:FindFirstChild(p.Name)
                if cp and cp:IsA("BasePart") then
                    pcall(function() cp.Color = p.Color end)
                end
            end
        end
    end
end

function RealAvatar:ApplyR15(char, hum, data, snap)
    if not char:FindFirstChild("LowerTorso") then
        return false, "LowerTorso missing"
    end

    self:Clear()
    self.active = true
    self.char = char
    local token = self.token
    local limitations = {}
    local attempts = {}
    local target = buildShapeTarget(data, snap.hipCalib)

    -- 1) Auto scaling OFF before anything changes: target parts are already scaled
    pcall(function() hum.AutomaticScalingEnabled = false end)
    for key, valueName in pairs(SCALE_VALUE_NAMES) do
        local v = hum:FindFirstChild(valueName)
        if not v then
            v = Instance.new("NumberValue")
            v.Name = valueName
            v.Parent = hum
        end
        if data.Scales[key] then
            v.Value = data.Scales[key]
        end
    end
    task.wait()

    -- 2) Remove old accessories / clothing, remember tools
    local tools = {}
    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Accessory") or ch:IsA("Shirt") or ch:IsA("Pants") or ch:IsA("ShirtGraphic")
            or ch:IsA("CharacterMesh") then
            ch:Destroy()
        elseif ch:IsA("Tool") then
            table.insert(tools, ch)
        end
    end

    -- 3) Replace body parts with the target's parts
    for _, name in ipairs(REPLACE_ORDER) do
        local tPart = target.Body[name]
        if tPart and not replacePart(char, hum, name, tPart, target) then
            table.insert(limitations, "Could not replace " .. name)
            log("[REAL] replace failed:", name)
        end
    end

    -- 4) Shape pass: sizes, joints, root, hip height
    task.wait(0.1)
    enforceShape(char, hum, target, attempts)

    -- 5) Colors, clothing, accessories
    setBodyColors(char, data.Template)
    applyLooks(char, hum, data)

    -- 6) Shape pass again after accessories
    task.wait(0.2)
    enforceShape(char, hum, target, attempts)

    -- 7) Tools
    for _, tool in ipairs(tools) do
        if tool.Parent == char then
            self:WatchTool(char, tool)
        end
    end
    table.insert(self.conns, char.ChildAdded:Connect(function(ch)
        if ch:IsA("Tool") then
            self:WatchTool(char, ch)
        end
    end))

    -- 8) Shape guard: once per second, only fixes what the game changed back
    task.spawn(function()
        while self.active and self.token == token and char.Parent do
            task.wait(1)
            if not (self.active and self.token == token and char.Parent) then break end
            pcall(function()
                enforceShape(char, hum, target, attempts)
            end)
        end
    end)

    log("[REAL] R15 avatar applied, limitations=" .. #limitations)
    return true, limitations
end

function RealAvatar:ApplyR6(char, hum, data)
    self:Clear()
    self.active = true
    self.char = char
    local limitations = {}

    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Accessory") or ch:IsA("Shirt") or ch:IsA("Pants") or ch:IsA("ShirtGraphic")
            or ch:IsA("CharacterMesh") then
            ch:Destroy()
        end
    end

    setBodyColors(char, data.Template)

    local cHead = char:FindFirstChild("Head")
    local tHead = data.Template:FindFirstChild("Head")
    if cHead and tHead then
        local tm = tHead:FindFirstChildOfClass("SpecialMesh")
        if tm then
            local cm = cHead:FindFirstChildOfClass("SpecialMesh")
            if not cm then
                cm = Instance.new("SpecialMesh")
                cm.Parent = cHead
            end
            pcall(function()
                cm.MeshType = tm.MeshType
                cm.MeshId = tm.MeshId
                cm.TextureId = tm.TextureId
                cm.Scale = tm.Scale
                cm.Offset = tm.Offset
            end)
        end
        local tf = tHead:FindFirstChild("face")
        if tf and tf:IsA("Decal") then
            local cf = cHead:FindFirstChild("face")
            if not cf then
                cf = Instance.new("Decal")
                cf.Name = "face"
                cf.Face = Enum.NormalId.Front
                cf.Parent = cHead
            end
            cf.Texture = tf.Texture
        end
    end

    applyLooks(char, hum, data)
    log("[REAL] R6 avatar applied")
    return true, limitations
end

function RealAvatar:Apply(char, data)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        return false, "Humanoid missing"
    end
    local localRig = (hum.RigType == Enum.HumanoidRigType.R6) and "R6" or "R15"
    if data.Rig ~= localRig then
        return false, "Avatar rig (" .. data.Rig .. ") does not match your rig (" .. localRig .. ")"
    end

    local snap = captureOriginal(char, hum) -- before the first change
    snap.modified = true

    if localRig == "R15" then
        return self:ApplyR15(char, hum, data, snap)
    end
    return self:ApplyR6(char, hum, data)
end

-- Puts your original avatar back (uses the snapshot taken before the first change)
function RealAvatar:Restore()
    local snap = Original
    if not snap or not snap.modified then
        return false, "Nothing to restore"
    end
    local char = snap.char
    if not char or not char.Parent then
        return false, "Original character no longer exists"
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        return false, "Humanoid missing"
    end

    self:Clear()

    local tools = {}
    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Tool") then
            table.insert(tools, ch)
        end
    end

    if snap.rig == Enum.HumanoidRigType.R15 then
        pcall(function() hum.AutomaticScalingEnabled = false end)
        for _, name in ipairs(REPLACE_ORDER) do
            local sp = snap.target.Body[name]
            if sp then
                replacePart(char, hum, name, sp, snap.target)
            end
        end
        task.wait(0.1)
        local attempts = {}
        enforceShape(char, hum, snap.target, attempts)
    end

    for _, ch in ipairs(char:GetChildren()) do
        if isLook(ch) then
            ch:Destroy()
        end
    end
    for _, l in ipairs(snap.looks) do
        local c = l:Clone()
        if c:IsA("Accessory") then
            local handle = c:FindFirstChild("Handle")
            if handle then
                for _, w in ipairs(handle:GetChildren()) do
                    if w:IsA("JointInstance") or w:IsA("WeldConstraint") then
                        w:Destroy()
                    end
                end
            end
            local okA = pcall(function() hum:AddAccessory(c) end)
            if not okA or not c.Parent then
                c.Parent = char
            end
        else
            c.Parent = char
        end
    end
    task.wait(0.2)
    reattachAccessories(char)

    if snap.rig ~= Enum.HumanoidRigType.R15 then
        if snap.r6Colors then
            for name, col in pairs(snap.r6Colors) do
                local p = char:FindFirstChild(name)
                if p and p:IsA("BasePart") then
                    pcall(function() p.Color = col end)
                end
            end
        end
        if snap.r6Head then
            local cHead = char:FindFirstChild("Head")
            local r = snap.r6Head
            if cHead then
                local cm = cHead:FindFirstChildOfClass("SpecialMesh")
                if r.hadMesh then
                    if not cm then
                        cm = Instance.new("SpecialMesh")
                        cm.Parent = cHead
                    end
                    pcall(function()
                        cm.MeshType = r.meshType
                        cm.MeshId = r.meshId
                        cm.TextureId = r.textureId
                        cm.Scale = r.scale
                        cm.Offset = r.offset
                    end)
                elseif cm then
                    cm:Destroy()
                end
                local cf = cHead:FindFirstChild("face")
                if r.hadFace and r.faceTexture then
                    if not cf then
                        cf = Instance.new("Decal")
                        cf.Name = "face"
                        cf.Face = Enum.NormalId.Front
                        cf.Parent = cHead
                    end
                    cf.Texture = r.faceTexture
                elseif cf and cf:IsA("Decal") then
                    cf:Destroy()
                end
            end
        end
    end

    if snap.rig == Enum.HumanoidRigType.R15 then
        for _, tool in ipairs(tools) do
            if tool.Parent == char then
                pcall(function() self:AttachTool(char, tool) end)
            end
        end
        pcall(function() hum.AutomaticScalingEnabled = snap.autoScaling end)
    end

    snap.modified = false
    log("[REAL] original avatar restored")
    return true
end

local function ApplyAvatarData(char, data)
    local ok, res = RealAvatar:Apply(char, data)
    if ok then
        return res
    end
    return nil, res
end

--------------------------------------------------------------------
-- VALIDATION (target vs actual)
--------------------------------------------------------------------
local ValidateAvatar
do
local function nearly(a, b)
    return math.abs(a - b) <= 0.02 + 0.02 * math.abs(b)
end

local function sizeNear(a, b)
    return nearly(a.X, b.X) and nearly(a.Y, b.Y) and nearly(a.Z, b.Z)
end

local function meshIdOf(part)
    if part:IsA("MeshPart") then return part.MeshId end
    local sm = part:FindFirstChildOfClass("SpecialMesh")
    return sm and sm.MeshId or ""
end

local function textureOf(part)
    if part:IsA("MeshPart") then return part.TextureID end
    local sm = part:FindFirstChildOfClass("SpecialMesh")
    return sm and sm.TextureId or ""
end

local function colorEq(a, b)
    return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
end

local function hasValidAccessoryWeld(handle)
    for _, w in ipairs(handle:GetChildren()) do
        if w:IsA("JointInstance") and w.Part0 and w.Part1 then
            return true
        end
    end
    return false
end

function ValidateAvatar(char, data, limitations)
    local mism = {}
    local function fail(msg)
        table.insert(mism, msg)
        log("[VALIDATION] MISMATCH:", msg)
    end

    if not char or not char.Parent then
        fail("Character missing")
        return { Mismatches = mism, Limitations = limitations or {} }
    end

    for name, tPart in pairs(data.Body) do
        local cPart = char:FindFirstChild(name)
        if not cPart or not cPart:IsA("BasePart") then
            fail("Body part missing: " .. name)
        else
            if meshIdOf(cPart) ~= meshIdOf(tPart) then
                fail(name .. " mesh differs")
            end
            if textureOf(cPart) ~= textureOf(tPart) then
                fail(name .. " texture differs")
            end
            if not sizeNear(cPart.Size, tPart.Size) then
                fail(("%s size target=%s actual=%s"):format(name, tostring(tPart.Size), tostring(cPart.Size)))
            end
        end
    end

    local cHead = char:FindFirstChild("Head")
    if cHead then
        local cFc = cHead:FindFirstChildOfClass("FaceControls") ~= nil
        if cFc ~= data.Head.HasFaceControls then
            fail("Head FaceControls target=" .. tostring(data.Head.HasFaceControls) .. " actual=" .. tostring(cFc))
        end
        if data.Face.DecalTexture then
            local cFace = cHead:FindFirstChild("face")
            if not (cFace and cFace:IsA("Decal") and cFace.Texture == data.Face.DecalTexture) then
                fail("Face decal differs")
            end
        end
    end

    local tShirt = data.Template:FindFirstChildOfClass("Shirt")
    local tPants = data.Template:FindFirstChildOfClass("Pants")
    local tGraphic = data.Template:FindFirstChildOfClass("ShirtGraphic")
    local cShirt = char:FindFirstChildOfClass("Shirt")
    local cPants = char:FindFirstChildOfClass("Pants")
    local cGraphic = char:FindFirstChildOfClass("ShirtGraphic")
    if (tShirt ~= nil) ~= (cShirt ~= nil) or (tShirt and cShirt and tShirt.ShirtTemplate ~= cShirt.ShirtTemplate) then
        fail("Shirt differs")
    end
    if (tPants ~= nil) ~= (cPants ~= nil) or (tPants and cPants and tPants.PantsTemplate ~= cPants.PantsTemplate) then
        fail("Pants differs")
    end
    if (tGraphic ~= nil) ~= (cGraphic ~= nil) or (tGraphic and cGraphic and tGraphic.Graphic ~= cGraphic.Graphic) then
        fail("GraphicTShirt differs")
    end

    local function accKey(acc)
        local h = acc:FindFirstChild("Handle")
        return acc.Name .. "|" .. (h and h:IsA("MeshPart") and h.MeshId or "")
    end
    local want, have = {}, {}
    for _, a in ipairs(data.Accessories) do
        local k = accKey(a)
        want[k] = (want[k] or 0) + 1
    end
    for _, a in ipairs(char:GetChildren()) do
        if a:IsA("Accessory") then
            local k = accKey(a)
            have[k] = (have[k] or 0) + 1
            local h = a:FindFirstChild("Handle")
            if h and h:IsA("BasePart") and not hasValidAccessoryWeld(h) then
                fail("Accessory not attached: " .. a.Name)
            end
        end
    end
    for k, n in pairs(want) do
        if (have[k] or 0) < n then
            fail("Accessory missing: " .. k)
        end
    end

    local cbc = char:FindFirstChildOfClass("BodyColors")
    if cbc and data.HasBodyColors ~= false then
        local b = data.BodyColors
        if not (colorEq(cbc.HeadColor3, b.HeadColor3) and colorEq(cbc.TorsoColor3, b.TorsoColor3)
            and colorEq(cbc.LeftArmColor3, b.LeftArmColor3) and colorEq(cbc.RightArmColor3, b.RightArmColor3)
            and colorEq(cbc.LeftLegColor3, b.LeftLegColor3) and colorEq(cbc.RightLegColor3, b.RightLegColor3)) then
            fail("BodyColors differ")
        end
    end

    for _, l in ipairs(limitations or {}) do
        log("[VALIDATION] LIMITATION:", l)
    end

    return { Mismatches = mism, Limitations = limitations or {} }
end

end

--------------------------------------------------------------------
-- INPUT ROUTER (one connection per event type for the whole script)
--------------------------------------------------------------------
local moveHandlers, endHandlers = {}, {}

track(UserInputService.InputChanged:Connect(function(input)
    for i = 1, #moveHandlers do
        moveHandlers[i](input)
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    for i = 1, #endHandlers do
        endHandlers[i](input)
    end
end))

local function onPointerMove(fn) table.insert(moveHandlers, fn) end
local function onPointerEnd(fn) table.insert(endHandlers, fn) end

local function isPointerStart(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function isPointerMove(input, active)
    if not active then return false end
    if input == active then return true end
    return active.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement
end

local function isPointerEnd(input, active)
    if not active then return false end
    if input == active then return true end
    return active.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseButton1
end

local function getViewport()
    local cam = workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

--------------------------------------------------------------------
-- UI: WINDOW
--------------------------------------------------------------------
local WIN_W, WIN_H = 560, 344

local screenGui = make("ScreenGui", {
    Name = GUI_NAME,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
    IgnoreGuiInset = true,
}, playerGui)

local mainFrame = make("Frame", {
    Name = "MainWindow",
    Size = UDim2.fromOffset(WIN_W, WIN_H),
    Position = State.mainPosition,
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
}, screenGui)
corner(mainFrame, 10)
stroke(mainFrame, C.line, 1)

local uiScale = make("UIScale", {}, mainFrame)
local function updateScale()
    local vp = getViewport()
    uiScale.Scale = math.clamp(math.min((vp.X - 24) / WIN_W, (vp.Y - 24) / WIN_H, 1), 0.5, 1)
end
updateScale()
if workspace.CurrentCamera then
    track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale))
end

-- Header
local header = make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 40),
    BackgroundTransparency = 1,
}, mainFrame)
make("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.new(0, 0, 1, -1),
    BackgroundColor3 = C.line,
    BorderSizePixel = 0,
}, header)

text(header, {
    Name = "Title",
    Size = UDim2.new(0, 200, 1, 0),
    Position = UDim2.new(0, 16, 0, 0),
    Text = "Avatar Copier",
    Font = F.bold,
    TextSize = 16,
})

text(header, {
    Name = "Credit",
    Size = UDim2.fromOffset(150, 40),
    Position = UDim2.fromOffset(142, 0),
    Text = "by ai && mbg34",
    Font = F.bold,
    TextSize = 14,
    TextColor3 = C.accent,
})

local scannerBtn = button(header, {
    Name = "ScannerBtn", Size = UDim2.fromOffset(92, 28), Position = UDim2.new(1, -250, 0, 6),
    Text = "NPC Scanner", TextSize = 13,
})
local settingsBtn = button(header, {
    Name = "SettingsBtn", Size = UDim2.fromOffset(70, 28), Position = UDim2.new(1, -152, 0, 6),
    Text = "Settings", TextSize = 13,
})
local minimizeBtn = button(header, {
    Name = "MinimizeBtn", Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -74, 0, 6),
    Text = "–", TextSize = 16,
})
local closeBtn = button(header, {
    Name = "CloseBtn", Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -40, 0, 6),
    Text = "×", TextSize = 18, Hover = C.bad,
})

-- Search
local searchBox = make("Frame", {
    Name = "SearchBox",
    Size = UDim2.fromOffset(300, 34),
    Position = UDim2.fromOffset(12, 52),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
}, mainFrame)
corner(searchBox, 8)

local searchInput = make("TextBox", {
    Name = "SearchInput",
    Size = UDim2.fromOffset(132, 34),
    Position = UDim2.fromOffset(12, 0),
    BackgroundTransparency = 1,
    PlaceholderText = "Name or ID",
    PlaceholderColor3 = C.dim,
    Text = "",
    TextColor3 = C.text,
    Font = F.med,
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ClearTextOnFocus = false,
}, searchBox)

local clearBtn = make("TextButton", {
    Name = "ClearBtn",
    Size = UDim2.fromOffset(22, 22),
    Position = UDim2.fromOffset(146, 6),
    BackgroundTransparency = 1,
    Text = "×",
    Font = F.bold,
    TextSize = 18,
    TextColor3 = C.sub,
    Visible = false,
}, searchBox)

-- NPC-only mode toggle
local npcBtn = button(searchBox, {
    Name = "NpcBtn", Size = UDim2.fromOffset(50, 26), Position = UDim2.fromOffset(170, 4),
    Text = "NPC", TextSize = 12, Font = F.bold,
})

local searchBtn = button(searchBox, {
    Name = "SearchBtn", Size = UDim2.fromOffset(68, 26), Position = UDim2.new(1, -74, 0.5, -13),
    Text = "Search", Bg = C.accent, Hover = C.accentHover, TextColor = C.onAccent, Font = F.bold,
})

local resultsTitle = text(mainFrame, {
    Name = "ResultsTitle",
    Size = UDim2.fromOffset(300, 16),
    Position = UDim2.fromOffset(14, 94),
    Text = "RESULTS",
    Font = F.bold,
    TextSize = 11,
    TextColor3 = C.sub,
})

local resultsFrame = make("ScrollingFrame", {
    Name = "ResultsFrame",
    Size = UDim2.fromOffset(300, 196),
    Position = UDim2.fromOffset(12, 112),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = C.line,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, mainFrame)
make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, resultsFrame)

local emptyResults = text(mainFrame, {
    Name = "EmptyResults",
    Size = UDim2.fromOffset(300, 60),
    Position = UDim2.fromOffset(12, 150),
    Text = EMPTY_HINT,
    TextSize = 12,
    TextColor3 = C.dim,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Center,
})

-- Selected card
local card = make("Frame", {
    Name = "SelectedCard",
    Size = UDim2.fromOffset(224, 256),
    Position = UDim2.fromOffset(324, 52),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
}, mainFrame)
corner(card, 10)

local cardEmpty = text(card, {
    Name = "CardEmpty",
    Size = UDim2.fromOffset(200, 80),
    Position = UDim2.fromOffset(12, 40),
    Text = "No user selected",
    TextSize = 13,
    TextColor3 = C.dim,
    TextXAlignment = Enum.TextXAlignment.Center,
})

local selectedInfo = make("Frame", {
    Name = "SelectedInfo",
    Size = UDim2.fromOffset(224, 150),
    BackgroundTransparency = 1,
    Visible = false,
}, card)

local selThumb = make("ImageLabel", {
    Name = "SelThumb",
    Size = UDim2.fromOffset(80, 80),
    Position = UDim2.fromOffset(12, 12),
    BackgroundColor3 = C.panel2,
    BorderSizePixel = 0,
    Image = "",
}, selectedInfo)
corner(selThumb, 8)
local selThumbTag = text(selThumb, {
    Size = UDim2.fromScale(1, 1),
    Text = "NPC",
    Font = F.bold,
    TextSize = 20,
    TextColor3 = C.warn,
    TextXAlignment = Enum.TextXAlignment.Center,
    Visible = false,
})

local selName = text(selectedInfo, {
    Size = UDim2.fromOffset(108, 20), Position = UDim2.fromOffset(104, 14),
    Font = F.bold, TextSize = 15, ClipsDescendants = true, Text = "",
})
local selUser = text(selectedInfo, {
    Size = UDim2.fromOffset(108, 16), Position = UDim2.fromOffset(104, 35),
    TextSize = 12, TextColor3 = C.sub, ClipsDescendants = true, Text = "",
})
local selTags = text(selectedInfo, {
    Size = UDim2.fromOffset(108, 40), Position = UDim2.fromOffset(104, 56),
    TextSize = 11, TextColor3 = C.sub, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Text = "",
})
text(selectedInfo, {
    Size = UDim2.fromOffset(200, 48), Position = UDim2.fromOffset(12, 100),
    TextSize = 11, TextColor3 = C.dim, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    Text = "Copy puts this avatar on your character. Restore brings your original one back.",
})

local copyBtn = button(card, {
    Name = "CopyBtn", Size = UDim2.fromOffset(200, 36), Position = UDim2.fromOffset(12, 170),
    Text = "Copy avatar", Bg = C.accent, Hover = C.accentHover, TextColor = C.onAccent, Font = F.bold,
    TextSize = 14, Radius = 8,
})
local previewBtn = button(card, {
    Name = "PreviewBtn", Size = UDim2.fromOffset(96, 30), Position = UDim2.fromOffset(12, 214),
    Text = "3D preview", Radius = 8,
})
local restoreBtn = button(card, {
    Name = "RestoreBtn", Size = UDim2.fromOffset(96, 30), Position = UDim2.fromOffset(116, 214),
    Text = "Restore", Radius = 8,
})
setDisabled(copyBtn, true)
setDisabled(previewBtn, true)
setDisabled(restoreBtn, true)

-- Status bar
make("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.fromOffset(0, WIN_H - 28),
    BackgroundColor3 = C.line,
    BorderSizePixel = 0,
}, mainFrame)
local statusDot = make("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.fromOffset(16, WIN_H - 18),
    BackgroundColor3 = C.dim,
    BorderSizePixel = 0,
}, mainFrame)
corner(statusDot, 4)
local statusLabel = text(mainFrame, {
    Name = "StatusLabel",
    Size = UDim2.new(1, -44, 0, 27),
    Position = UDim2.fromOffset(32, WIN_H - 27),
    TextSize = 12,
    TextColor3 = C.sub,
    ClipsDescendants = true,
    Text = "Ready",
})

local function setStatus(msg, color)
    statusLabel.Text = msg
    statusDot.BackgroundColor3 = color or C.dim
end

local function refreshButtons()
    setDisabled(copyBtn, State.selectedUser == nil or State.copying)
    setDisabled(previewBtn, State.selectedUser == nil)
    setDisabled(restoreBtn, not SelectedAvatar.Active or State.busy > 0)
    copyBtn.Text = State.copying and "Copying..." or "Copy avatar"
end

local function renderNpcToggle()
    local on = State.npcOnly
    npcBtn:SetAttribute("Base", on and C.accent or C.panel2)
    npcBtn:SetAttribute("Hover", on and C.accentHover or C.line)
    npcBtn:SetAttribute("BaseText", on and C.onAccent or C.text)
    npcBtn.BackgroundColor3 = on and C.accent or C.panel2
    npcBtn.TextColor3 = on and C.onAccent or C.text
    searchInput.PlaceholderText = on and "Filter NPCs" or "Name or ID"
end

-- Floating button (shows your own headshot)
local floatBtn = make("ImageButton", {
    Name = "FloatingButton",
    Size = UDim2.fromOffset(48, 48),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(1, -40, 0.5, 0),
    BackgroundColor3 = C.panel,
    Image = "rbxthumb://type=AvatarHeadShot&id=" .. localPlayer.UserId .. "&w=150&h=150",
    AutoButtonColor = false,
    Visible = false,
    Active = true,
}, screenGui)
corner(floatBtn, 24)
stroke(floatBtn, C.accent, 2)

--------------------------------------------------------------------
-- UI: 3D PREVIEW
--------------------------------------------------------------------
local viewerOverlay = make("Frame", {
    Name = "ViewerOverlay",
    Size = UDim2.new(1, 0, 1, -41),
    Position = UDim2.fromOffset(0, 41),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 20,
    Active = true,
}, mainFrame)

local viewerTitle = text(viewerOverlay, {
    Size = UDim2.new(1, -100, 0, 28), Position = UDim2.fromOffset(16, 6),
    Font = F.bold, TextSize = 14, Text = "3D preview", ClipsDescendants = true,
})
local viewerClose = button(viewerOverlay, {
    Size = UDim2.fromOffset(64, 26), Position = UDim2.new(1, -76, 0, 7), Text = "Close",
})

local viewportFrame = make("ViewportFrame", {
    Name = "ModelViewport",
    Size = UDim2.new(1, -24, 1, -76),
    Position = UDim2.fromOffset(12, 40),
    BackgroundColor3 = C.panel,
    Ambient = Color3.fromRGB(170, 170, 180),
    LightColor = Color3.fromRGB(240, 240, 240),
    LightDirection = Vector3.new(-1, -1.6, -1).Unit,
    BorderSizePixel = 0,
}, viewerOverlay)
corner(viewportFrame, 8)

local viewerHint = text(viewerOverlay, {
    Size = UDim2.new(1, -150, 0, 20), Position = UDim2.new(0, 16, 1, -28),
    Text = "Drag to rotate, scroll or pinch to zoom", TextSize = 11, TextColor3 = C.dim,
})
local zoomInBtn = button(viewerOverlay, {
    Size = UDim2.fromOffset(28, 24), Position = UDim2.new(1, -120, 1, -30), Text = "+", TextSize = 16,
})
local zoomOutBtn = button(viewerOverlay, {
    Size = UDim2.fromOffset(28, 24), Position = UDim2.new(1, -88, 1, -30), Text = "–", TextSize = 16,
})
local resetCamBtn = button(viewerOverlay, {
    Size = UDim2.fromOffset(44, 24), Position = UDim2.new(1, -56, 1, -30), Text = "Reset", TextSize = 12,
})

local Preview = {
    state = "Closed",
    model = nil,
    camera = nil,
    rotation = 0,
    elevation = 8,
    zoom = 10,
    framing = 10,
    center = Vector3.zero,
    loadToken = 0,
    dirty = false,
    conn = nil,
}

local function applyPreviewCamera()
    if not Preview.camera then return end
    local re, el = math.rad(Preview.rotation), math.rad(Preview.elevation)
    local ce = math.cos(el)
    local offset = Vector3.new(
        math.sin(re) * ce * Preview.zoom,
        math.sin(el) * Preview.zoom,
        math.cos(re) * ce * Preview.zoom
    )
    Preview.camera.CFrame = CFrame.lookAt(Preview.center + offset, Preview.center)
    Preview.dirty = false
end

local function setPreviewZoom(value)
    Preview.zoom = math.clamp(value, Preview.framing * 0.3, Preview.framing * 2.5)
    Preview.dirty = true
end

local function Close3DViewer()
    Preview.loadToken += 1
    Preview.state = "Closed"
    viewerOverlay.Visible = false
    if Preview.conn then
        Preview.conn:Disconnect()
        Preview.conn = nil
    end
    if Preview.model then
        Preview.model:Destroy()
        Preview.model = nil
    end
    if Preview.camera then
        viewportFrame.CurrentCamera = nil
        Preview.camera:Destroy()
        Preview.camera = nil
    end
end

local function partExtents(p)
    local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = p.CFrame:GetComponents()
    local s = p.Size
    local ex = (math.abs(r00) * s.X + math.abs(r01) * s.Y + math.abs(r02) * s.Z) / 2
    local ey = (math.abs(r10) * s.X + math.abs(r11) * s.Y + math.abs(r12) * s.Z) / 2
    local ez = (math.abs(r20) * s.X + math.abs(r21) * s.Y + math.abs(r22) * s.Z) / 2
    return Vector3.new(x, y, z), Vector3.new(ex, ey, ez)
end

--------------------------------------------------------------------
-- 3D PREVIEW BUILDING BLOCKS
-- The preview keeps the Humanoid (clothing / layered clothing need it; it
-- never simulates inside a ViewportFrame), re-assembles the pose from the
-- joints, and only shows the model once everything is loaded.
--------------------------------------------------------------------
local function countLooks(m)
    local n = 0
    for _, c in ipairs(m:GetChildren()) do
        if c:IsA("Accessory") or c:IsA("Shirt") or c:IsA("Pants") or c:IsA("ShirtGraphic") then
            n += 1
        end
    end
    return n
end

-- One clean, never-displayed model per avatar. It is built once and cloned for every preview.
-- Players: the template (exactly what Copy applies), unless a model freshly built from the
-- HumanoidDescription has more clothing / accessories. NPCs: a clone of the NPC template.
local function getPreviewMaster(data)
    if data.PreviewMaster then
        return data.PreviewMaster
    end

    local master
    if data.IsNpc then
        master = data.Template:Clone()
    else
        local wantRig = (data.Rig == "R6") and Enum.HumanoidRigType.R6 or Enum.HumanoidRigType.R15
        local alt
        pcall(function()
            alt = Players:CreateHumanoidModelFromDescription(data.Description, wantRig)
        end)

        if alt and countLooks(alt) > countLooks(data.Template) then
            prepareTemplate(alt)
            master = alt
            log("[PREVIEW] using model built from the description")
        else
            if alt then alt:Destroy() end
            master = data.Template:Clone()
        end
    end
    master.Name = "PreviewMaster"
    data.PreviewMaster = master
    return master
end

-- Rebuilds the rest pose from the joints (Motor6D, Weld, ManualWeld), starting at the root.
-- Handles both joint directions, so accessory welds are placed correctly too.
-- Joints are disabled afterwards, so moving one part can never drag the others around.
local function assemblePreviewPose(model, rootCF)
    local root = model:FindFirstChild("HumanoidRootPart")
    if not (root and root:IsA("BasePart")) then
        root = model:FindFirstChild("Torso") or model:FindFirstChild("LowerTorso")
    end
    if not (root and root:IsA("BasePart")) then
        return false
    end

    local joints = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("JointInstance") and d.Part0 and d.Part1 then
            joints[#joints + 1] = d
        end
    end

    local cfs = { [root] = rootCF }
    local queue, head = { root }, 1
    while head <= #queue do
        local cur = queue[head]
        head += 1
        local curCF = cfs[cur]
        for _, j in ipairs(joints) do
            local p0, p1 = j.Part0, j.Part1
            if p0 == cur and cfs[p1] == nil then
                cfs[p1] = curCF * j.C0 * j.C1:Inverse()
                queue[#queue + 1] = p1
            elseif p1 == cur and cfs[p0] == nil then
                cfs[p0] = curCF * j.C1 * j.C0:Inverse()
                queue[#queue + 1] = p0
            end
        end
    end

    for _, j in ipairs(joints) do
        pcall(function() j.Enabled = false end)
    end
    for part, cf in pairs(cfs) do
        part.Anchored = true
        part.CFrame = cf
    end
    return true
end

local function preloadWithTimeout(inst, timeout)
    local done = false
    task.spawn(function()
        pcall(function() ContentProvider:PreloadAsync({ inst }) end)
        done = true
    end)
    local waited = 0
    while not done and waited < timeout do
        task.wait(0.05)
        waited += 0.05
    end
end

local function Open3DViewer(userData)
    if not userData then
        setStatus("Select a user first", C.bad)
        return
    end

    Close3DViewer()
    local myToken = Preview.loadToken
    Preview.state = "Loading"
    viewerTitle.Text = "Loading " .. userData.DisplayName .. " ..."
    viewerOverlay.Visible = true
    viewportFrame.Visible = false -- shown only when the model is complete

    task.spawn(function()
        local function stale()
            return Preview.loadToken ~= myToken or dead()
        end

        local data, err = GetAvatarData(userData)
        if stale() then return end
        if not data then
            viewerTitle.Text = "Preview failed: " .. tostring(err)
            Preview.state = "Closed"
            return
        end

        local master = getPreviewMaster(data)
        if stale() then return end

        local model = master:Clone()
        model.Name = "PreviewModel"

        -- The Humanoid STAYS (clothing, body colors and layered clothing need it),
        -- but it must never run or draw UI.
        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum.AutomaticScalingEnabled = false end)
            pcall(function() hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end)
            pcall(function() hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff end)
            pcall(function() hum.EvaluateStateMachine = false end)
        end

        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BaseScript") or d:IsA("ForceField") or d:IsA("Sound") or d:IsA("Tool") then
                d:Destroy()
            elseif d:IsA("BasePart") then
                d.Anchored = true
                d.CanCollide = false
                d.CanTouch = false
                d.CanQuery = false
            end
        end

        -- Rest pose, facing the camera (+Z), always upright
        local posed = assemblePreviewPose(model, CFrame.Angles(0, math.pi, 0))
        if not posed then
            pcall(function() model:PivotTo(CFrame.Angles(0, math.pi, 0)) end)
        end

        -- Load every mesh / texture / clothing template BEFORE the model becomes visible
        viewerTitle.Text = "Loading " .. userData.DisplayName .. " ..."
        preloadWithTimeout(model, 10)
        if stale() then
            model:Destroy()
            return
        end

        model.Parent = viewportFrame
        Preview.model = model

        local camera = Instance.new("Camera")
        camera.FieldOfView = 40
        camera.Parent = viewportFrame
        viewportFrame.CurrentCamera = camera
        Preview.camera = camera

        -- Frame the body parts only, so huge accessories cannot push the camera away
        local minV, maxV
        for _, name in ipairs(data.Rig == "R15" and R15_PARTS or R6_PARTS) do
            local p = model:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                local c, e = partExtents(p)
                local lo, hi = c - e, c + e
                if minV then
                    minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
                    maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
                else
                    minV, maxV = lo, hi
                end
            end
        end
        if not minV then
            minV, maxV = Vector3.new(-2, 0, -1), Vector3.new(2, 6, 1)
        end
        local size = maxV - minV
        Preview.center = (minV + maxV) / 2

        local tanHalf = math.tan(math.rad(camera.FieldOfView / 2))
        local vs = viewportFrame.AbsoluteSize
        local aspect = (vs.Y > 0) and (vs.X / vs.Y) or 1.5
        local needY = (size.Y / 2 + 0.6) / tanHalf
        local needX = (math.max(size.X, size.Z) / 2 + 0.6) / (tanHalf * aspect)
        Preview.framing = math.max(needY, needX) * 1.1
        Preview.zoom = Preview.framing
        Preview.rotation = 0
        Preview.elevation = 8

        applyPreviewCamera()
        Preview.conn = RunService.RenderStepped:Connect(function()
            if Preview.dirty then
                applyPreviewCamera()
            end
        end)

        -- Give the renderer a moment to apply clothing / layered clothing, then reveal
        task.wait(0.25)
        if stale() then return end
        viewportFrame.Visible = true
        Preview.state = "Ready"
        if userData.IsNpc then
            viewerTitle.Text = userData.DisplayName .. "  (NPC)"
        else
            viewerTitle.Text = userData.DisplayName .. "  @" .. userData.Username
        end

        -- Late assets (slow textures) are picked up by the renderer on their own
        task.spawn(function()
            preloadWithTimeout(model, 8)
        end)
    end)
end

onClick(viewerClose, Close3DViewer)
onClick(resetCamBtn, function()
    Preview.rotation = 0
    Preview.elevation = 8
    Preview.zoom = Preview.framing
    Preview.dirty = true
end)
onClick(zoomInBtn, function() setPreviewZoom(Preview.zoom - Preview.framing * 0.15) end)
onClick(zoomOutBtn, function() setPreviewZoom(Preview.zoom + Preview.framing * 0.15) end)

do
    local touches, dragInput, lastPos, lastPinch = {}, nil, Vector2.zero, nil

    track(viewportFrame.InputBegan:Connect(function(input)
        if not isPointerStart(input) then return end
        if input.UserInputType == Enum.UserInputType.Touch then
            touches[input] = Vector2.new(input.Position.X, input.Position.Y)
        end
        if not dragInput then
            dragInput = input
            lastPos = Vector2.new(input.Position.X, input.Position.Y)
        end
    end))

    track(viewportFrame.InputChanged:Connect(function(input)
        if Preview.state == "Ready" and input.UserInputType == Enum.UserInputType.MouseWheel then
            setPreviewZoom(Preview.zoom - input.Position.Z * Preview.framing * 0.1)
        end
    end))

    onPointerMove(function(input)
        if Preview.state ~= "Ready" then return end
        if touches[input] then
            touches[input] = Vector2.new(input.Position.X, input.Position.Y)
        end
        local pts = {}
        for _, p in pairs(touches) do
            pts[#pts + 1] = p
        end
        if #pts >= 2 then
            local dist = (pts[1] - pts[2]).Magnitude
            if lastPinch then
                setPreviewZoom(Preview.zoom - (dist - lastPinch) * Preview.framing * 0.004)
            end
            lastPinch = dist
            return
        end
        lastPinch = nil
        if dragInput and isPointerMove(input, dragInput) then
            local cur = Vector2.new(input.Position.X, input.Position.Y)
            local delta = cur - lastPos
            lastPos = cur
            Preview.rotation -= delta.X * 0.6
            Preview.elevation = math.clamp(Preview.elevation + delta.Y * 0.4, -30, 60)
            Preview.dirty = true
        end
    end)

    onPointerEnd(function(input)
        touches[input] = nil
        if dragInput and isPointerEnd(input, dragInput) then
            dragInput = nil
        end
    end)
end

--------------------------------------------------------------------
-- UI: DRAGGING / MINIMIZE
--------------------------------------------------------------------
local function ClampWindowPosition(px, py, frame)
    local vp = getViewport()
    local w = frame.AbsoluteSize.X
    local h = frame.AbsoluteSize.Y
    local halfW = w * frame.AnchorPoint.X
    local halfH = h * frame.AnchorPoint.Y
    local minX = halfW - w * 0.15
    local maxX = vp.X - (w - halfW) + w * 0.15
    local minY = halfH - h * 0.1
    local maxY = vp.Y - (h - halfH) + h * 0.15
    if maxX < minX then maxX = minX end
    if maxY < minY then maxY = minY end
    return UDim2.fromOffset(math.clamp(px, minX, maxX), math.clamp(py, minY, maxY))
end

local function makeDraggable(handle, target, clampFn, onEnd)
    local active, dragStart, startPos, moved = nil, nil, nil, 0

    track(handle.InputBegan:Connect(function(input)
        if isPointerStart(input) and not active then
            active = input
            dragStart = input.Position
            startPos = target.Position
            moved = 0
        end
    end))

    onPointerMove(function(input)
        if active and isPointerMove(input, active) then
            local delta = input.Position - dragStart
            moved = math.max(moved, delta.Magnitude)
            local vp = getViewport()
            local x = startPos.X.Scale * vp.X + startPos.X.Offset + delta.X
            local y = startPos.Y.Scale * vp.Y + startPos.Y.Offset + delta.Y
            target.Position = clampFn(x, y, target)
        end
    end)

    onPointerEnd(function(input)
        if active and isPointerEnd(input, active) then
            active = nil
            if onEnd then onEnd(moved) end
        end
    end)

    return function() return moved end
end

makeDraggable(header, mainFrame, ClampWindowPosition, function()
    State.mainPosition = mainFrame.Position
end)

local floatMoved = makeDraggable(floatBtn, floatBtn, function(x, y)
    local vp = getViewport()
    return UDim2.fromOffset(math.clamp(x, 24, math.max(24, vp.X - 24)), math.clamp(y, 24, math.max(24, vp.Y - 24)))
end, function(moved)
    if moved >= 8 then
        State.floatPosition = floatBtn.Position
    end
end)

-- Window show / hide (used by the minimize button, the floating button and the hotkey)
local function showWindow()
    floatBtn.Visible = false
    mainFrame.Position = State.mainPosition
    mainFrame.Visible = true
end

local function hideWindow()
    mainFrame.Visible = false
    if State.floatPosition then
        floatBtn.Position = State.floatPosition
    end
    floatBtn.Visible = true
end

local function toggleWindow()
    if mainFrame.Visible then
        hideWindow()
    else
        showWindow()
    end
end

track(floatBtn.Activated:Connect(function()
    if floatMoved() < 8 then
        showWindow()
    end
end))

onClick(minimizeBtn, hideWindow)

--------------------------------------------------------------------
-- NPC SCANNER (finds every NPC in the workspace)
-- NPC = a Model that contains a Humanoid and is not a player's character.
--------------------------------------------------------------------
local NpcIds = setmetatable({}, { __mode = "k" })
local NpcCounter = 0
local NpcScan = { list = {}, time = 0, busy = false }

local function firstBasePart(model)
    for _, n in ipairs({ "HumanoidRootPart", "Torso", "UpperTorso", "Head" }) do
        local p = model:FindFirstChild(n)
        if p and p:IsA("BasePart") then
            return p
        end
    end
    if model.PrimaryPart then
        return model.PrimaryPart
    end
    return model:FindFirstChildWhichIsA("BasePart")
end

local function liveNpcList()
    local out = {}
    for _, info in ipairs(NpcScan.list) do
        if info.Model and info.Model.Parent then
            table.insert(out, info)
        end
    end
    return out
end

-- Returns the list of NPC infos sorted by distance. Cached for a few seconds unless force is true.
local function ScanNpcs(force)
    if NpcScan.busy then
        local waited = 0
        while NpcScan.busy and waited < 15 do
            task.wait(0.05)
            waited += 0.05
        end
        return liveNpcList()
    end
    if not force and NpcScan.time > 0 and os.clock() - NpcScan.time < 4 then
        return liveNpcList()
    end

    NpcScan.busy = true
    local ok, result = pcall(function()
        local found, seen = {}, {}
        local char = localPlayer.Character
        local myRoot = char and char:FindFirstChild("HumanoidRootPart")
        local myPos = myRoot and myRoot.Position
        local descendants = workspace:GetDescendants()

        for i, d in ipairs(descendants) do
            if d:IsA("Humanoid") then
                local model = d.Parent
                if model and model:IsA("Model") and not seen[model] and model ~= char
                    and not Players:GetPlayerFromCharacter(model)
                    and (model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")) then
                    seen[model] = true
                    local id = NpcIds[model]
                    if not id then
                        NpcCounter += 1
                        id = -NpcCounter
                        NpcIds[model] = id
                    end
                    local part = firstBasePart(model)
                    local dist = (part and myPos) and (part.Position - myPos).Magnitude or math.huge
                    local rigName = (d.RigType == Enum.HumanoidRigType.R15) and "R15" or "R6"
                    local distText = dist < math.huge and (math.floor(dist + 0.5) .. " studs") or "unknown distance"
                    table.insert(found, {
                        Id = id,
                        IsNpc = true,
                        Model = model,
                        Username = model.Name,
                        DisplayName = (d.DisplayName ~= "") and d.DisplayName or model.Name,
                        RigName = rigName,
                        Distance = dist,
                        HasVerifiedBadge = false,
                        IsOnline = false,
                        SubText = model.Name .. " · " .. rigName .. " · " .. distText,
                    })
                end
            end
            if i % 4000 == 0 then
                task.wait()
            end
        end

        table.sort(found, function(a, b)
            return a.Distance < b.Distance
        end)
        return found
    end)
    NpcScan.busy = false

    if ok and result then
        NpcScan.list = result
        NpcScan.time = os.clock()
        log("NPC scan:", #result, "NPCs found")
    else
        warn("[AvatarCopier] NPC scan error: " .. tostring(result))
    end
    return liveNpcList()
end

local function npcMatches(list, query, limit)
    local q = (query or ""):lower()
    local out = {}
    for _, info in ipairs(list) do
        if q == "" or info.Username:lower():find(q, 1, true) or info.DisplayName:lower():find(q, 1, true) then
            table.insert(out, info)
            if #out >= limit then break end
        end
    end
    return out
end

--------------------------------------------------------------------
-- USER LOOKUP / SEARCH
--------------------------------------------------------------------
local function getUserInfo(userId)
    if userInfoCache[userId] then
        return userInfoCache[userId]
    end

    local success, result = pcall(function()
        return UserService:GetUserInfosByUserIdsAsync({ userId })
    end)
    if success and result and #result > 0 then
        local info = {
            Id = result[1].Id,
            Username = result[1].Username,
            DisplayName = result[1].DisplayName,
            HasVerifiedBadge = result[1].HasVerifiedBadge or false,
        }
        userInfoCache[userId] = info
        return info
    end

    local nameSuccess, name = pcall(function()
        return Players:GetNameFromUserIdAsync(userId)
    end)
    if nameSuccess and name then
        local info = { Id = userId, Username = name, DisplayName = name, HasVerifiedBadge = false }
        userInfoCache[userId] = info
        return info
    end
    return nil
end

local rowByUser = {}

local function clearResultsList()
    State.renderToken += 1
    for _, child in ipairs(resultsFrame:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
    table.clear(rowByUser)
end

local function RankSearchResults(results, query)
    local q = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #q == 0 then return results end

    for _, item in ipairs(results) do
        local u = (item.Username or ""):lower()
        local d = (item.DisplayName or ""):lower()
        local score
        if u == q then
            score = 1000000
        elseif d == q then
            score = 800000
        elseif #u >= #q and u:sub(1, #q) == q then
            score = 500000 - (#u - #q) * 100
        elseif #d >= #q and d:sub(1, #q) == q then
            score = 400000 - (#d - #q) * 100
        elseif u:find(q, 1, true) then
            score = 200000 - u:find(q, 1, true) * 50 - (#u - #q) * 10
        elseif d:find(q, 1, true) then
            score = 100000 - d:find(q, 1, true) * 50 - (#d - #q) * 10
        else
            local common = 0
            for ch in q:gmatch(".") do
                if u:find(ch, 1, true) or d:find(ch, 1, true) then
                    common += 1
                end
            end
            score = 1000 + common * 50
        end
        item.MatchScore = score
    end

    table.sort(results, function(a, b)
        return (a.MatchScore or 0) > (b.MatchScore or 0)
    end)
    return results
end

local SelectUser -- forward declaration

local function highlightSelected()
    local id = State.selectedUser and State.selectedUser.Id
    for userId, row in pairs(rowByUser) do
        local selected = userId == id
        row.BackgroundColor3 = selected and C.panel2 or C.panel
        local bar = row:FindFirstChild("Bar")
        if bar then
            bar.Visible = selected
        end
    end
end

local function createRow(data, order)
    local row = make("TextButton", {
        Name = "Row",
        Size = UDim2.new(1, -8, 0, 46),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = order,
    }, resultsFrame)
    corner(row, 8)
    rowByUser[data.Id] = row

    local bar = make("Frame", {
        Name = "Bar",
        Size = UDim2.fromOffset(3, 24),
        Position = UDim2.new(0, 0, 0.5, -12),
        BackgroundColor3 = C.accent,
        BorderSizePixel = 0,
        Visible = false,
    }, row)
    corner(bar, 2)

    if data.IsNpc then
        local thumb = make("Frame", {
            Size = UDim2.fromOffset(32, 32),
            Position = UDim2.fromOffset(12, 7),
            BackgroundColor3 = C.panel2,
            BorderSizePixel = 0,
        }, row)
        corner(thumb, 16)
        text(thumb, {
            Size = UDim2.fromScale(1, 1), Text = "NPC", Font = F.bold, TextSize = 10,
            TextColor3 = C.warn, TextXAlignment = Enum.TextXAlignment.Center,
        })
    else
        local thumb = make("ImageLabel", {
            Size = UDim2.fromOffset(32, 32),
            Position = UDim2.fromOffset(12, 7),
            BackgroundColor3 = C.panel2,
            BorderSizePixel = 0,
            Image = "rbxthumb://type=AvatarHeadShot&id=" .. data.Id .. "&w=150&h=150",
        }, row)
        corner(thumb, 16)
    end

    text(row, {
        Size = UDim2.new(1, -130, 0, 18), Position = UDim2.fromOffset(54, 6),
        Font = F.bold, TextSize = 13, ClipsDescendants = true, Text = data.DisplayName,
    })
    text(row, {
        Size = UDim2.new(1, -130, 0, 14), Position = UDim2.fromOffset(54, 25),
        TextSize = 11, TextColor3 = C.sub, ClipsDescendants = true,
        Text = data.SubText or ("@" .. data.Username),
    })

    local tagText = data.IsNpc and data.RigName
        or (data.IsOnline and "In server") or (data.Unavailable and "ID only") or data.RigType
    if tagText then
        local tagColor = C.sub
        if data.IsNpc then
            tagColor = C.warn
        elseif data.IsOnline then
            tagColor = C.accent
        end
        local tag = text(row, {
            Size = UDim2.fromOffset(56, 18), Position = UDim2.new(1, -64, 0.5, -9),
            BackgroundTransparency = 0, BackgroundColor3 = C.panel2, Font = F.med, TextSize = 10,
            TextColor3 = tagColor, Text = tagText,
            TextXAlignment = Enum.TextXAlignment.Center,
        })
        corner(tag, 4)
    end

    track(row.MouseEnter:Connect(function()
        if not (State.selectedUser and State.selectedUser.Id == data.Id) then
            row.BackgroundColor3 = C.panel2
        end
    end))
    track(row.MouseLeave:Connect(function()
        if not (State.selectedUser and State.selectedUser.Id == data.Id) then
            row.BackgroundColor3 = C.panel
        end
    end))
    track(row.Activated:Connect(function()
        SelectUser(data)
    end))
    return row
end

local function renderResultsList(results, npcMode)
    clearResultsList()
    local myToken = State.renderToken

    if #results == 0 then
        if npcMode then
            emptyResults.Text = "No NPCs found.\nTry another name, or open NPC Scanner and press Rescan."
            setStatus("No NPCs found", C.bad)
        else
            emptyResults.Text = "No users found.\nBanned or deleted account? Search by the numeric user ID."
            setStatus("No users found", C.bad)
        end
        emptyResults.Visible = true
        resultsTitle.Text = npcMode and "NPCs" or "RESULTS"
        return
    end

    emptyResults.Visible = false
    resultsTitle.Text = (npcMode and "NPCs" or "RESULTS") .. "  ·  " .. #results
    setStatus("Found " .. #results .. (npcMode and " NPCs. Pick one from the list." or " matches. Pick a user from the list."), C.accent)

    -- Rows are created a few per frame so a long list never stalls the game
    for i, data in ipairs(results) do
        if State.renderToken ~= myToken or dead() then return end
        createRow(data, i)
        if i % 8 == 0 then
            task.wait()
        end
    end
    if State.renderToken == myToken then
        highlightSelected()
    end
end

-- Normal mode: players + up to 5 matching NPCs
local function mergeNpcResults(players, query)
    local merged = {}
    for _, p in ipairs(players) do
        table.insert(merged, p)
    end
    local list = ScanNpcs(false)
    for _, info in ipairs(npcMatches(list, query, 5)) do
        table.insert(merged, info)
    end
    RankSearchResults(merged, query)
    return merged
end

local function SearchUsers(query, force)
    query = string.gsub(query, "^%s*(.-)%s*$", "%1")
    State.searchToken += 1
    local searchToken = State.searchToken

    -- NPC-only mode: an empty query lists every NPC
    if State.npcOnly then
        setStatus("Scanning NPCs...", C.warn)
        local list = ScanNpcs(force == true)
        if State.searchToken ~= searchToken or dead() then return end
        renderResultsList(npcMatches(list, query, 200), true)
        return
    end

    if query == "" then
        clearResultsList()
        emptyResults.Text = EMPTY_HINT
        emptyResults.Visible = true
        resultsTitle.Text = "RESULTS"
        setStatus("Ready", C.dim)
        return
    end

    local maxR = Settings.MaxResults
    local cacheKey = query .. "|" .. maxR
    if searchCache[cacheKey] then
        local merged = mergeNpcResults(searchCache[cacheKey], query)
        if State.searchToken ~= searchToken or dead() then return end
        renderResultsList(merged)
        return
    end

    setStatus("Searching...", C.warn)

    local candidates = {}
    local seenIds = {}
    local qLower = query:lower()

    for _, p in ipairs(Players:GetPlayers()) do
        if not seenIds[p.UserId] and #candidates < maxR then
            if p.Name:lower():find(qLower, 1, true) or p.DisplayName:lower():find(qLower, 1, true) then
                seenIds[p.UserId] = true
                local char = p.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                table.insert(candidates, {
                    Id = p.UserId,
                    Username = p.Name,
                    DisplayName = p.DisplayName,
                    HasVerifiedBadge = false,
                    IsOnline = true,
                    RigType = hum and (hum.RigType == Enum.HumanoidRigType.R15 and "R15" or "R6") or nil,
                })
            end
        end
    end

    -- A numeric ID is always added, even if Roblox hides the name (banned/deleted)
    local numId = tonumber(query)
    if numId and numId > 0 and numId == math.floor(numId) and not seenIds[numId] then
        local info = getUserInfo(numId)
        if not info then
            info = {
                Id = numId,
                Username = "user_" .. numId,
                DisplayName = "ID " .. numId,
                HasVerifiedBadge = false,
                Unavailable = true,
            }
        end
        seenIds[numId] = true
        info.IsOnline = false
        table.insert(candidates, info)
    end

    local exactUserId = nil
    if not numId or numId <= 0 then
        local okName, foundId = pcall(function()
            return Players:GetUserIdFromNameAsync(query)
        end)
        if okName and foundId and not seenIds[foundId] then
            exactUserId = foundId
            seenIds[foundId] = true
            local info = getUserInfo(foundId) or {
                Id = foundId, Username = query, DisplayName = query,
                HasVerifiedBadge = false, Unavailable = true,
            }
            info.IsOnline = false
            table.insert(candidates, info)
        end
    end

    local function scanFriends(userId)
        pcall(function()
            local pages = Players:GetFriendsAsync(userId)
            local maxPages = math.clamp(math.ceil(maxR / 20), 2, 6)
            local pageIdx = 1
            while pageIdx <= maxPages do
                for _, item in ipairs(pages:GetCurrentPage()) do
                    if not seenIds[item.Id] and #candidates < maxR then
                        if item.Username:lower():find(qLower, 1, true)
                            or item.DisplayName:lower():find(qLower, 1, true) then
                            seenIds[item.Id] = true
                            table.insert(candidates, {
                                Id = item.Id,
                                Username = item.Username,
                                DisplayName = item.DisplayName or item.Username,
                                HasVerifiedBadge = false,
                                IsOnline = false,
                            })
                        end
                    end
                end
                if pages.IsFinished or #candidates >= maxR then break end
                if not pcall(function() pages:AdvanceToNextPageAsync() end) then break end
                pageIdx += 1
            end
        end)
    end

    scanFriends(localPlayer.UserId)
    if State.searchToken ~= searchToken or dead() then return end

    if exactUserId and #candidates < maxR then
        scanFriends(exactUserId)
    end

    if #candidates < maxR and not numId then
        for _, suf in ipairs({ "1", "123", "_roblox", "gaming", "dev" }) do
            if #candidates >= maxR or State.searchToken ~= searchToken or dead() then break end
            local ok, testId = pcall(function() return Players:GetUserIdFromNameAsync(query .. suf) end)
            if ok and testId and not seenIds[testId] then
                seenIds[testId] = true
                local info = getUserInfo(testId)
                if info then
                    info.IsOnline = false
                    table.insert(candidates, info)
                end
            end
        end
    end

    if State.searchToken ~= searchToken or dead() then return end

    RankSearchResults(candidates, query)
    local finalResults = {}
    for i = 1, math.min(maxR, #candidates) do
        finalResults[i] = candidates[i]
    end

    searchCache[cacheKey] = finalResults -- players only; NPCs are merged fresh every time
    local merged = mergeNpcResults(finalResults, query)
    if State.searchToken ~= searchToken or dead() then return end
    renderResultsList(merged)
end

--------------------------------------------------------------------
-- SELECTION / ACTIONS
--------------------------------------------------------------------
function SelectUser(userData)
    State.selectedUser = userData
    State.selectToken += 1
    local myToken = State.selectToken
    log("Selected " .. userData.Username .. " (" .. userData.Id .. ")" .. (userData.IsNpc and " [NPC]" or ""))

    highlightSelected()

    cardEmpty.Visible = false
    selectedInfo.Visible = true
    if userData.IsNpc then
        selThumb.Image = ""
        selThumbTag.Visible = true
        selUser.Text = "NPC · " .. userData.Username
    else
        selThumbTag.Visible = false
        selThumb.Image = "rbxthumb://type=AvatarBust&id=" .. userData.Id .. "&w=150&h=150"
        selUser.Text = "@" .. userData.Username
    end
    selName.Text = userData.DisplayName
    selTags.Text = "Loading avatar data..."

    task.spawn(function()
        local data = GetAvatarData(userData)
        if State.selectToken ~= myToken or dead() then return end
        if not data then
            selTags.Text = "Avatar data unavailable"
            return
        end
        local tags = {}
        if data.IsNpc then
            table.insert(tags, "NPC")
        end
        table.insert(tags, data.Rig)
        if data.Head.IsDynamic then
            table.insert(tags, "Dynamic head")
        elseif data.Head.IsSpecial then
            table.insert(tags, "Special head")
        end
        if #data.LayeredClothing > 0 then
            table.insert(tags, "Layered")
        end
        if data.FromFallback then
            table.insert(tags, "Fallback data")
        end
        selTags.Text = table.concat(tags, "  ·  ")
    end)

    refreshButtons()
    if userData.IsNpc then
        setStatus("Selected NPC " .. userData.DisplayName, C.accent)
    else
        setStatus("Selected " .. userData.DisplayName .. " (@" .. userData.Username .. ")", C.accent)
    end
end

local function reportStatus(report)
    local nMism, nLim = #report.Mismatches, #report.Limitations
    if nMism == 0 and nLim == 0 then
        setStatus("Avatar copied and verified", C.accent)
    elseif nLim > 0 then
        setStatus("Limitation: " .. report.Limitations[1], C.warn)
    else
        setStatus(("Copied with %d difference(s): %s"):format(nMism, report.Mismatches[1]), C.warn)
    end
end

local function CopyAvatar(userData)
    if not userData or State.copying or dead() then return end
    State.copying = true
    State.busy += 1
    refreshButtons()

    task.spawn(function()
        local ok, err = pcall(function()
            local char = localPlayer.Character
            if not char or not char:FindFirstChildOfClass("Humanoid") then
                setStatus("Character not found", C.bad)
                return
            end

            local ownScales = getOwnScales(char) -- before any change to the character
            setStatus(userData.IsNpc and "Reading NPC..." or "Loading avatar data...", C.warn)
            refreshNpcCache(userData) -- NPCs: always copy the current look
            local data, derr = GetAvatarData(userData, localRigName(), ownScales)
            if dead() then return end -- exit was confirmed while loading: do not touch the character
            if not data then
                setStatus("Failed to load avatar: " .. tostring(derr), C.bad)
                return
            end

            setStatus("Copying avatar...", C.warn)
            local limitations, aerr = ApplyAvatarData(char, data)
            if not limitations then
                setStatus("Apply failed: " .. tostring(aerr), C.bad)
                return
            end

            local report = ValidateAvatar(char, data, limitations)
            SelectedAvatar.Active = true
            SelectedAvatar.UserId = userData.Id
            SelectedAvatar.Username = userData.Username
            SelectedAvatar.DisplayName = userData.DisplayName
            SelectedAvatar.Source = userData
            if not dead() then
                reportStatus(report)
            end
        end)
        State.copying = false
        State.busy -= 1
        if not ok then
            warn("[AvatarCopier] Copy error: " .. tostring(err))
            if not dead() then
                setStatus("Copy failed (see output)", C.bad)
            end
        end
        if not State.destroyed then
            refreshButtons()
        end
    end)
end

local function RestoreNow()
    if State.busy > 0 then return end
    State.busy += 1
    refreshButtons()
    task.spawn(function()
        setStatus("Restoring your original avatar...", C.warn)
        local ok, res, err = pcall(function()
            return RealAvatar:Restore()
        end)
        State.busy -= 1
        if State.destroyed then return end
        if ok and res then
            SelectedAvatar.Active = false
            setStatus("Original avatar restored", C.accent)
        else
            setStatus("Restore failed: " .. tostring(ok and err or res), C.bad)
        end
        refreshButtons()
    end)
end

onClick(previewBtn, function()
    if State.selectedUser then
        Open3DViewer(State.selectedUser)
    end
end)
onClick(copyBtn, function()
    if State.selectedUser then
        CopyAvatar(State.selectedUser)
    end
end)
onClick(restoreBtn, RestoreNow)

--------------------------------------------------------------------
-- NPC SCANNER VIEW
--------------------------------------------------------------------
local scannerView
local scannerToken = 0
do
scannerView = make("Frame", {
    Name = "ScannerView",
    Size = UDim2.new(1, 0, 1, -41),
    Position = UDim2.fromOffset(0, 41),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 20,
    Active = true,
}, mainFrame)

text(scannerView, {
    Size = UDim2.fromOffset(110, 28), Position = UDim2.fromOffset(16, 6),
    Font = F.bold, TextSize = 14, Text = "NPC Scanner",
})
local scannerCount = text(scannerView, {
    Size = UDim2.new(1, -270, 0, 28), Position = UDim2.fromOffset(126, 6),
    TextSize = 12, TextColor3 = C.sub, Text = "",
})
local scannerRescan = button(scannerView, {
    Size = UDim2.fromOffset(72, 26), Position = UDim2.new(1, -152, 0, 7), Text = "Rescan",
    Bg = C.accent, Hover = C.accentHover, TextColor = C.onAccent, Font = F.bold,
})
local scannerClose = button(scannerView, {
    Size = UDim2.fromOffset(64, 26), Position = UDim2.new(1, -76, 0, 7), Text = "Close",
})
local scannerList = make("ScrollingFrame", {
    Name = "ScannerList",
    Size = UDim2.new(1, -24, 1, -52),
    Position = UDim2.fromOffset(12, 42),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = C.line,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, scannerView)
make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, scannerList)
local scannerEmpty = text(scannerView, {
    Size = UDim2.new(1, -24, 0, 40), Position = UDim2.fromOffset(12, 110),
    Text = "", TextSize = 12, TextColor3 = C.dim, TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Center, Visible = false,
})


local function clearScannerList()
    for _, child in ipairs(scannerList:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
end

local function createScannerRow(info, order, myRig)
    local row = make("Frame", {
        Size = UDim2.new(1, -8, 0, 46),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        LayoutOrder = order,
    }, scannerList)
    corner(row, 8)

    text(row, {
        Size = UDim2.new(1, -150, 0, 18), Position = UDim2.fromOffset(12, 5),
        Font = F.bold, TextSize = 13, ClipsDescendants = true, Text = info.DisplayName,
    })
    local compatible = info.RigName == myRig
    text(row, {
        Size = UDim2.new(1, -150, 0, 14), Position = UDim2.fromOffset(12, 25),
        TextSize = 11, TextColor3 = compatible and C.sub or C.warn, ClipsDescendants = true,
        Text = info.SubText .. (compatible and "" or " · different rig"),
    })

    local selectB = button(row, {
        Size = UDim2.fromOffset(56, 28), Position = UDim2.new(1, -126, 0.5, -14),
        Text = "Select", TextSize = 12,
    })
    local copyB = button(row, {
        Size = UDim2.fromOffset(56, 28), Position = UDim2.new(1, -64, 0.5, -14),
        Text = "Copy", TextSize = 12, Bg = C.accent, Hover = C.accentHover, TextColor = C.onAccent, Font = F.bold,
    })
    if not compatible then
        setDisabled(copyB, true)
    end

    onClick(selectB, function()
        SelectUser(info)
        scannerView.Visible = false
    end)
    onClick(copyB, function()
        SelectUser(info)
        scannerView.Visible = false
        CopyAvatar(info)
    end)
end

local function refreshScanner(force)
    scannerToken += 1
    local myToken = scannerToken
    scannerCount.Text = "Scanning..."
    scannerEmpty.Visible = false
    clearScannerList()

    task.spawn(function()
        local list = ScanNpcs(force)
        if scannerToken ~= myToken or dead() then return end
        scannerCount.Text = (#list == 1) and "1 NPC found" or (#list .. " NPCs found")
        if #list == 0 then
            scannerEmpty.Text = "No NPCs found in this game."
            scannerEmpty.Visible = true
            return
        end
        local myRig = localRigName()
        for i, info in ipairs(list) do
            if scannerToken ~= myToken or dead() then return end
            createScannerRow(info, i, myRig)
            if i % 10 == 0 then
                task.wait()
            end
        end
    end)
end

onClick(scannerBtn, function()
    if scannerView.Visible then
        scannerView.Visible = false
        return
    end
    Close3DViewer()
    scannerView.Visible = true
    refreshScanner(true)
end)
onClick(scannerRescan, function()
    refreshScanner(true)
end)
onClick(scannerClose, function()
    scannerToken += 1
    scannerView.Visible = false
end)

end

--------------------------------------------------------------------
-- SETTINGS VIEW (scrollable)
--------------------------------------------------------------------
local settingsView, settingsScroll, makeToggle
do
settingsView = make("Frame", {
    Name = "SettingsView",
    Size = UDim2.new(1, 0, 1, -41),
    Position = UDim2.fromOffset(0, 41),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 20,
    Active = true,
}, mainFrame)

text(settingsView, {
    Size = UDim2.new(1, -120, 0, 28), Position = UDim2.fromOffset(16, 6),
    Font = F.bold, TextSize = 14, Text = "Settings",
})
local settingsDone = button(settingsView, {
    Size = UDim2.fromOffset(64, 26), Position = UDim2.new(1, -76, 0, 7), Text = "Done",
    Bg = C.accent, Hover = C.accentHover, TextColor = C.onAccent, Font = F.bold,
})

-- Everything below the title lives in this scrolling area
settingsScroll = make("ScrollingFrame", {
    Name = "SettingsScroll",
    Size = UDim2.new(1, 0, 1, -40),
    Position = UDim2.fromOffset(0, 40),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = C.line,
    CanvasSize = UDim2.fromOffset(0, 590),
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, settingsView)

-- Slider card
local sliderCard = make("Frame", {
    Size = UDim2.new(1, -28, 0, 72),
    Position = UDim2.fromOffset(12, 4),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
}, settingsScroll)
corner(sliderCard, 8)

text(sliderCard, {
    Size = UDim2.new(1, -90, 0, 18), Position = UDim2.fromOffset(14, 10),
    Font = F.bold, TextSize = 13, Text = "Max search results",
})
local sliderValue = text(sliderCard, {
    Size = UDim2.fromOffset(60, 18), Position = UDim2.new(1, -74, 0, 10),
    Font = F.bold, TextSize = 13, TextColor3 = C.accent, TextXAlignment = Enum.TextXAlignment.Right,
    Text = tostring(Settings.MaxResults),
})
local sliderTrack = make("Frame", {
    Size = UDim2.new(1, -40, 0, 6),
    Position = UDim2.fromOffset(20, 48),
    BackgroundColor3 = C.panel2,
    BorderSizePixel = 0,
}, sliderCard)
corner(sliderTrack, 3)
local sliderFill = make("Frame", {
    Size = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = C.accent,
    BorderSizePixel = 0,
}, sliderTrack)
corner(sliderFill, 3)
local sliderKnob = make("Frame", {
    Size = UDim2.fromOffset(16, 16),
    Position = UDim2.new(0, -8, 0.5, -8),
    BackgroundColor3 = C.text,
    BorderSizePixel = 0,
    ZIndex = 2,
}, sliderTrack)
corner(sliderKnob, 8)
local sliderHit = make("TextButton", {
    Size = UDim2.new(1, -16, 0, 30),
    Position = UDim2.fromOffset(8, 36),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    ZIndex = 3,
}, sliderCard)

local function setMaxResults(v)
    v = math.clamp(math.floor(v + 0.5), 1, 100)
    Settings.MaxResults = v
    local alpha = (v - 1) / 99
    sliderFill.Size = UDim2.new(alpha, 0, 1, 0)
    sliderKnob.Position = UDim2.new(alpha, -8, 0.5, -8)
    sliderValue.Text = tostring(v)
end
setMaxResults(Settings.MaxResults)

do
    local sliding = nil
    local function updateFromX(x)
        local w = sliderTrack.AbsoluteSize.X
        if w <= 0 then return end
        setMaxResults(1 + math.clamp((x - sliderTrack.AbsolutePosition.X) / w, 0, 1) * 99)
    end
    track(sliderHit.InputBegan:Connect(function(input)
        if isPointerStart(input) and not sliding then
            sliding = input
            updateFromX(input.Position.X)
        end
    end))
    onPointerMove(function(input)
        if sliding and isPointerMove(input, sliding) then
            updateFromX(input.Position.X)
        end
    end)
    onPointerEnd(function(input)
        if sliding and isPointerEnd(input, sliding) then
            sliding = nil
            if #searchInput.Text > 0 then
                task.spawn(SearchUsers, searchInput.Text)
            end
        end
    end)
end

function makeToggle(yPos, title, desc, initial, onChange)
    local row = make("Frame", {
        Size = UDim2.new(1, -28, 0, 56),
        Position = UDim2.fromOffset(12, yPos),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
    }, settingsScroll)
    corner(row, 8)
    text(row, {
        Size = UDim2.new(1, -90, 0, 18), Position = UDim2.fromOffset(14, 10),
        Font = F.bold, TextSize = 13, Text = title,
    })
    text(row, {
        Size = UDim2.new(1, -90, 0, 16), Position = UDim2.fromOffset(14, 30),
        TextSize = 11, TextColor3 = C.sub, Text = desc,
    })
    local sw = make("TextButton", {
        Size = UDim2.fromOffset(46, 24),
        Position = UDim2.new(1, -60, 0.5, -12),
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, row)
    corner(sw, 12)
    local knob = make("Frame", {
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = C.text,
        BorderSizePixel = 0,
    }, sw)
    corner(knob, 9)

    local state = initial
    local function render()
        sw.BackgroundColor3 = state and C.accent or C.panel2
        knob.Position = state and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
    end
    render()
    track(sw.Activated:Connect(function()
        state = not state
        render()
        onChange(state)
    end))
end

makeToggle(84, "Keep avatar after respawn", "Re-apply the copy automatically when you respawn",
    Settings.KeepOnRespawn, function(v)
        Settings.KeepOnRespawn = v
        setStatus("Keep after respawn: " .. (v and "on" or "off"), C.accent)
    end)

makeToggle(146, "Copy body shape", "Off: the target's looks on your own proportions (players only)",
    Settings.CopyShape, function(v)
        Settings.CopyShape = v
        setStatus("Copy body shape: " .. (v and "on" or "off") .. " (applies on the next copy)", C.accent)
    end)

onClick(settingsBtn, function()
    scannerView.Visible = false
    settingsView.Visible = not settingsView.Visible
end)
onClick(settingsDone, function()
    settingsView.Visible = false
end)

end

--------------------------------------------------------------------
-- RESPAWN
--------------------------------------------------------------------
local function HandleRespawn(newChar)
    if not (SelectedAvatar.Active and SelectedAvatar.UserId) then return end
    if not Settings.KeepOnRespawn then
        SelectedAvatar.Active = false
        refreshButtons()
        return
    end

    State.respawnToken += 1
    local thisToken = State.respawnToken
    State.busy += 1

    task.spawn(function()
        local hum = newChar:WaitForChild("Humanoid", 8)
        local root = newChar:WaitForChild("HumanoidRootPart", 8)
        if hum and root then
            if hum.RigType == Enum.HumanoidRigType.R15 then
                newChar:WaitForChild("LowerTorso", 8)
            end
            task.wait(0.35)
            if State.respawnToken == thisToken and not dead() and newChar.Parent and Settings.KeepOnRespawn then
                local ownScales = getOwnScales(newChar) -- fresh character, not modified yet
                local rigName = (hum.RigType == Enum.HumanoidRigType.R6) and "R6" or "R15"
                local source = SelectedAvatar.Source or {
                    Id = SelectedAvatar.UserId,
                    Username = SelectedAvatar.Username or "User",
                    DisplayName = SelectedAvatar.DisplayName or "User",
                }
                local data = GetAvatarData(source, rigName, ownScales)
                if data and not dead() and newChar.Parent then
                    local ok, limitations = pcall(ApplyAvatarData, newChar, data)
                    if ok and limitations then
                        ValidateAvatar(newChar, data, limitations)
                    end
                end
            end
        end
        State.busy -= 1
    end)
end

track(localPlayer.CharacterAdded:Connect(HandleRespawn))

--------------------------------------------------------------------
-- EXIT (confirmation, restore original avatar, full cleanup)
--------------------------------------------------------------------
local exitOverlay = make("Frame", {
    Name = "ExitOverlay",
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 40,
    Active = true,
}, mainFrame)

local exitDialog = make("Frame", {
    Size = UDim2.fromOffset(320, 150),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
}, exitOverlay)
corner(exitDialog, 10)
stroke(exitDialog, C.line, 1)

text(exitDialog, {
    Size = UDim2.new(1, -32, 0, 22), Position = UDim2.fromOffset(16, 16),
    Font = F.bold, TextSize = 16, Text = "Exit Avatar Copier?",
})
local exitMessage = text(exitDialog, {
    Size = UDim2.new(1, -32, 0, 40), Position = UDim2.fromOffset(16, 44),
    TextSize = 13, TextColor3 = C.sub, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    Text = "The script will be turned off completely and your original avatar will be restored.",
})
local exitNo = button(exitDialog, {
    Size = UDim2.fromOffset(136, 34), Position = UDim2.fromOffset(16, 100), Text = "No", Radius = 8,
})
local exitYes = button(exitDialog, {
    Size = UDim2.fromOffset(136, 34), Position = UDim2.fromOffset(168, 100), Text = "Yes, exit",
    Bg = C.bad, Hover = C.badHover, TextColor = Color3.new(1, 1, 1), Font = F.bold, Radius = 8,
})

local function ShutDown(restore)
    if State.shuttingDown then return end
    State.shuttingDown = true
    State.abort = true -- in-flight copy/respawn work will not touch the character any more

    -- Let an apply that is already running finish, then undo it
    local waited = 0
    while State.busy > 0 and waited < 12 do
        task.wait(0.05)
        waited += 0.05
    end
    RealAvatar:Clear()

    if restore then
        local ok, res, err = pcall(function()
            return RealAvatar:Restore()
        end)
        if not ok then
            warn("[AvatarCopier] Restore error: " .. tostring(res))
        elseif not res then
            log("restore skipped:", tostring(err))
        end
    end

    State.destroyed = true
    scannerToken += 1
    log("Copier destroyed")

    Close3DViewer()
    if State.searchTimer then
        pcall(task.cancel, State.searchTimer)
        State.searchTimer = nil
    end

    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)
    table.clear(moveHandlers)
    table.clear(endHandlers)

    for key, data in pairs(DataCache) do
        if data.Template then
            pcall(function() data.Template:Destroy() end)
        end
        if data.PreviewMaster then
            pcall(function() data.PreviewMaster:Destroy() end)
        end
        DataCache[key] = nil
    end
    destroySnapshot(Original)
    Original = nil

    if screenGui and screenGui.Parent then
        screenGui:Destroy()
    end
end

onClick(closeBtn, function()
    exitOverlay.Visible = true
end)
onClick(exitNo, function()
    exitOverlay.Visible = false
end)
onClick(exitYes, function()
    setDisabled(exitYes, true)
    setDisabled(exitNo, true)
    exitMessage.Text = "Restoring your original avatar..."
    task.spawn(ShutDown, true)
end)

-- If the gui is destroyed from outside (for example the script is run again), still restore
screenGui.Destroying:Connect(function()
    if not State.shuttingDown then
        ShutDown(true)
    end
end)

--------------------------------------------------------------------
-- HOTKEYS (keyboard shortcuts, configurable in Settings)
--
--  * Master switch + one rebindable key per action.
--  * Click a key button, then press the new key:
--      Esc = cancel, Backspace = clear the binding.
--  * Ignored while typing in a text box (the game "processes" those keys).
--  * Saved to AvatarCopier_hotkeys.json if the executor has writefile/readfile.
--------------------------------------------------------------------
local HOTKEY_FILE = "AvatarCopier_hotkeys.json"

local HOTKEY_DEFS = {
    { id = "ToggleWindow", title = "Show / hide window", desc = "Works while the window is minimized too", default = Enum.KeyCode.RightShift },
    { id = "Copy",         title = "Copy selected avatar", desc = "Same as the Copy avatar button",       default = Enum.KeyCode.Insert },
    { id = "Restore",      title = "Restore original avatar", desc = "Same as the Restore button",         default = Enum.KeyCode.Delete },
    { id = "Preview",      title = "3D preview", desc = "Open or close the preview of the selected avatar", default = Enum.KeyCode.PageUp },
    { id = "Search",       title = "Focus search box", desc = "Jump straight into the search field",       default = Enum.KeyCode.Home },
}

-- Keys that must not be bound (they would break movement / typing)
local BLOCKED_KEYS = {
    [Enum.KeyCode.W] = true, [Enum.KeyCode.A] = true, [Enum.KeyCode.S] = true, [Enum.KeyCode.D] = true,
    [Enum.KeyCode.Space] = true, [Enum.KeyCode.Return] = true, [Enum.KeyCode.Tab] = true,
    [Enum.KeyCode.Unknown] = true,
}

local Hotkeys = {
    enabled = true,
    binds = {},       -- id -> Enum.KeyCode or nil
    listening = nil,  -- id currently waiting for a key
}

local function resetBinds()
    for _, d in ipairs(HOTKEY_DEFS) do
        Hotkeys.binds[d.id] = d.default
    end
end
resetBinds()

local function hotkeyTitle(id)
    for _, d in ipairs(HOTKEY_DEFS) do
        if d.id == id then
            return d.title
        end
    end
    return id
end

local function canUseFiles()
    return type(writefile) == "function" and type(readfile) == "function"
end

local function saveHotkeys()
    if not canUseFiles() then return end
    local out = { enabled = Hotkeys.enabled, binds = {} }
    for _, d in ipairs(HOTKEY_DEFS) do
        local k = Hotkeys.binds[d.id]
        out.binds[d.id] = k and k.Name or ""
    end
    pcall(function()
        writefile(HOTKEY_FILE, HttpService:JSONEncode(out))
    end)
end

local function loadHotkeys()
    if not canUseFiles() then return end
    pcall(function()
        if type(isfile) == "function" and not isfile(HOTKEY_FILE) then return end
        local data = HttpService:JSONDecode(readfile(HOTKEY_FILE))
        if type(data) ~= "table" then return end
        if type(data.enabled) == "boolean" then
            Hotkeys.enabled = data.enabled
        end
        if type(data.binds) == "table" then
            for _, d in ipairs(HOTKEY_DEFS) do
                local name = data.binds[d.id]
                if name == "" then
                    Hotkeys.binds[d.id] = nil
                elseif type(name) == "string" then
                    local okK, kc = pcall(function() return Enum.KeyCode[name] end)
                    if okK and kc and not BLOCKED_KEYS[kc] then
                        Hotkeys.binds[d.id] = kc
                    end
                end
            end
        end
    end)
end
loadHotkeys()

-- Settings UI: master switch
makeToggle(208, "Enable hotkeys", "Keyboard shortcuts for PC. On mobile use the floating button.",
    Hotkeys.enabled, function(v)
        Hotkeys.enabled = v
        Hotkeys.listening = nil
        saveHotkeys()
        setStatus("Hotkeys: " .. (v and "on" or "off"), C.accent)
    end)

text(settingsScroll, {
    Size = UDim2.new(1, -40, 0, 16), Position = UDim2.fromOffset(16, 274),
    Text = "HOTKEYS   (click a key, then press the new one · Esc cancel · Backspace clear)",
    Font = F.bold, TextSize = 11, TextColor3 = C.sub,
})

local keyButtons = {}

local function renderKeyButtons()
    for _, d in ipairs(HOTKEY_DEFS) do
        local b = keyButtons[d.id]
        if b then
            local base, hover, txtColor, label
            if Hotkeys.listening == d.id then
                base, hover, txtColor, label = C.accent, C.accentHover, C.onAccent, "Press a key..."
            else
                local k = Hotkeys.binds[d.id]
                base, hover, txtColor = C.panel2, C.line, k and C.text or C.dim
                label = k and k.Name or "None"
            end
            b:SetAttribute("Base", base)
            b:SetAttribute("Hover", hover)
            b:SetAttribute("BaseText", txtColor)
            b.BackgroundColor3 = base
            b.TextColor3 = txtColor
            b.Text = label
        end
    end
end

for i, d in ipairs(HOTKEY_DEFS) do
    local row = make("Frame", {
        Size = UDim2.new(1, -28, 0, 40),
        Position = UDim2.fromOffset(12, 294 + (i - 1) * 46),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
    }, settingsScroll)
    corner(row, 8)
    text(row, {
        Size = UDim2.new(1, -150, 0, 18), Position = UDim2.fromOffset(14, 4),
        Font = F.bold, TextSize = 13, ClipsDescendants = true, Text = d.title,
    })
    text(row, {
        Size = UDim2.new(1, -150, 0, 14), Position = UDim2.fromOffset(14, 22),
        TextSize = 11, TextColor3 = C.sub, ClipsDescendants = true, Text = d.desc,
    })
    local kb = button(row, {
        Name = "Key_" .. d.id,
        Size = UDim2.fromOffset(112, 26), Position = UDim2.new(1, -124, 0.5, -13),
        Text = "", TextSize = 12, Font = F.bold,
    })
    keyButtons[d.id] = kb
    onClick(kb, function()
        if Hotkeys.listening == d.id then
            Hotkeys.listening = nil
        else
            Hotkeys.listening = d.id
            setStatus("Press a key for \"" .. d.title .. "\"  (Esc cancel, Backspace clear)", C.warn)
        end
        renderKeyButtons()
    end)
end

local resetKeysBtn = button(settingsScroll, {
    Name = "ResetKeys", Size = UDim2.fromOffset(150, 28), Position = UDim2.fromOffset(12, 294 + #HOTKEY_DEFS * 46 + 4),
    Text = "Reset hotkeys", TextSize = 12,
})
onClick(resetKeysBtn, function()
    Hotkeys.listening = nil
    resetBinds()
    saveHotkeys()
    renderKeyButtons()
    setStatus("Hotkeys reset to defaults", C.accent)
end)
renderKeyButtons()

-- Hotkey actions
local function runHotkey(id)
    if id == "ToggleWindow" then
        toggleWindow()
        return
    end

    if id == "Copy" then
        if State.selectedUser then
            CopyAvatar(State.selectedUser)
        else
            setStatus("Hotkey: select a user or NPC first", C.bad)
        end
        return
    end

    if id == "Restore" then
        if SelectedAvatar.Active and State.busy == 0 then
            RestoreNow()
        else
            setStatus("Nothing to restore", C.warn)
        end
        return
    end

    -- the remaining actions need the window to be open
    if not mainFrame.Visible then return end

    if id == "Preview" then
        if Preview.state ~= "Closed" then
            Close3DViewer()
        elseif State.selectedUser then
            settingsView.Visible = false
            scannerView.Visible = false
            Open3DViewer(State.selectedUser)
        else
            setStatus("Hotkey: select a user or NPC first", C.bad)
        end
        return
    end

    if id == "Search" then
        settingsView.Visible = false
        scannerView.Visible = false
        -- wait one frame so the hotkey itself is not typed into the box
        task.spawn(function()
            task.wait()
            if not dead() then
                searchInput:CaptureFocus()
            end
        end)
    end
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if dead() then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local key = input.KeyCode

    -- Rebinding mode: the next key becomes the new binding
    if Hotkeys.listening then
        local id = Hotkeys.listening
        Hotkeys.listening = nil

        if key == Enum.KeyCode.Escape then
            setStatus("Rebinding cancelled", C.dim)
        elseif key == Enum.KeyCode.Backspace then
            Hotkeys.binds[id] = nil
            saveHotkeys()
            setStatus("\"" .. hotkeyTitle(id) .. "\": hotkey cleared", C.accent)
        elseif BLOCKED_KEYS[key] then
            setStatus("That key cannot be used (" .. key.Name .. ")", C.bad)
        else
            local moved
            for otherId, k in pairs(Hotkeys.binds) do
                if otherId ~= id and k == key then
                    Hotkeys.binds[otherId] = nil
                    moved = otherId
                end
            end
            Hotkeys.binds[id] = key
            saveHotkeys()
            if moved then
                setStatus(key.Name .. " is now \"" .. hotkeyTitle(id) .. "\" (removed from \"" .. hotkeyTitle(moved) .. "\")", C.warn)
            else
                setStatus("\"" .. hotkeyTitle(id) .. "\" = " .. key.Name, C.accent)
            end
        end
        renderKeyButtons()
        return
    end

    if processed or not Hotkeys.enabled then return end
    if exitOverlay.Visible or State.shuttingDown then return end

    for _, d in ipairs(HOTKEY_DEFS) do
        if Hotkeys.binds[d.id] == key then
            runHotkey(d.id)
            return
        end
    end
end))

--------------------------------------------------------------------
-- SEARCH INPUT WIRING
--------------------------------------------------------------------
local function runSearchSoon(delaySeconds, force)
    if State.searchTimer then
        pcall(task.cancel, State.searchTimer)
    end
    State.searchTimer = task.delay(delaySeconds, function()
        State.searchTimer = nil
        if not dead() then
            SearchUsers(searchInput.Text, force)
        end
    end)
end

track(searchInput:GetPropertyChangedSignal("Text"):Connect(function()
    clearBtn.Visible = #searchInput.Text > 0
    runSearchSoon(0.45, false)
end))

track(searchInput.FocusLost:Connect(function(enterPressed)
    if enterPressed then
        runSearchSoon(0, true)
    end
end))

onClick(searchBtn, function()
    runSearchSoon(0, true)
end)

-- NPC-only mode: lists only NPCs (an empty search shows every NPC)
onClick(npcBtn, function()
    State.npcOnly = not State.npcOnly
    renderNpcToggle()
    if State.npcOnly then
        setStatus("NPC mode: only NPCs are listed", C.accent)
    else
        setStatus("Players + NPC search", C.dim)
    end
    runSearchSoon(0, true)
end)
renderNpcToggle()

track(clearBtn.Activated:Connect(function()
    searchInput.Text = ""
    clearBtn.Visible = false
    clearResultsList()
    State.selectedUser = nil
    State.selectToken += 1
    Close3DViewer()

    cardEmpty.Visible = true
    selectedInfo.Visible = false
    emptyResults.Text = EMPTY_HINT
    emptyResults.Visible = true
    resultsTitle.Text = "RESULTS"
    refreshButtons()
    setStatus("Ready", C.dim)
    if State.npcOnly then
        runSearchSoon(0, false)
    end
end))

refreshButtons()
log("Avatar Copier v23.0 loaded")
