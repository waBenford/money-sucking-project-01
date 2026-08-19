--[[
	QuestUi
	The Traveler panel, in two views sharing one frame:

	  List   -- every Story Level as a row. Only the level you are ON is
	            clickable: it is that level's quest.
	  Detail -- what the quest costs (money + one Story of each rarity from that
	            level) against what it gives (the next level's Stories).

	Opened by walking to the NPC and pressing E -- QuestInteraction fires the
	OpenRequest signal this script creates below.

	Money and StoryLevel are IntValues inside leaderstats, so they replicate to
	this client for free; inventory counts come over the same remotes BedUi uses.
	The panel reads all three and re-renders on their changes, which is why it
	needs no quest-specific state remote.

	The unlock request carries no arguments at all. Every check here is courtesy
	-- the server re-derives the cost, re-checks the inventory, and is the only
	thing that can spend anything.

	Layout follows BedUi: one fixed design space (DESIGN_WIDTH x DESIGN_HEIGHT)
	with a UIScale shrinking the panel to fit the viewport.

	Styling seams: createLevelRow() builds a list row, createCostRow() and
	createRewardRow() build the detail lines. Nothing else touches row visuals.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QuestConfig = require(Shared:WaitForChild("QuestConfig"))
local StoryData = require(Shared:WaitForChild("StoryData"))
local Theme = require(Shared:WaitForChild("Theme"))

-- Timed, so a missing instance says so instead of yielding forever. An untimed
-- WaitForChild here would leave the script hanging with the UI simply absent --
-- the hardest kind of failure to diagnose.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("QuestUi: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local UnlockLevel = Remotes:WaitForChild("UnlockLevel", 10)
local UnlockResult = Remotes:WaitForChild("UnlockResult", 10)
local GetInventory = Remotes:WaitForChild("GetInventory", 10)
local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated", 10)

if not (UnlockLevel and UnlockResult and GetInventory and InventoryUpdated) then
	warn("QuestUi: Remotes is missing UnlockLevel, UnlockResult, GetInventory or InventoryUpdated")
	return
end

local player = Players.LocalPlayer

-- PlayerData builds leaderstats on join, which can land after this script runs.
local leaderstats = player:WaitForChild("leaderstats", 20)
local money = leaderstats and leaderstats:WaitForChild("Money", 10)
local storyLevel = leaderstats and leaderstats:WaitForChild("StoryLevel", 10)

if not (money and storyLevel) then
	warn("QuestUi: leaderstats.Money or leaderstats.StoryLevel is missing -- is PlayerData running?")
	return
end

--// Configuration

-- The design space every offset below is written in. The panel never renders at
-- more than 1:1; it only ever scales down.
local DESIGN_WIDTH = 960
local DESIGN_HEIGHT = 480

local VIEWPORT_MARGIN_X = 0.92
local VIEWPORT_MARGIN_Y = 0.86
local MIN_SCALE = 0.4

local PADDING = 16
local GAP = 12
local HEADER_HEIGHT = 40
local FOOTER_HEIGHT = 40
local ROW_HEIGHT = 54
local COST_ROW_HEIGHT = 34

local NPC_WIDTH = 200
local NPC_SPIN_SPEED = math.rad(30) -- radians per second

local BODY_Y = PADDING + HEADER_HEIGHT + GAP
local BODY_HEIGHT = DESIGN_HEIGHT - BODY_Y - PADDING
local RIGHT_X = PADDING + NPC_WIDTH + GAP
local RIGHT_WIDTH = DESIGN_WIDTH - RIGHT_X - PADDING

--// State

local counts = {} -- [storyId] = count, the inventory as the panel knows it
local activeQuestLevel = nil -- nil = list view, number = detail view
local statusOverride = nil -- one-shot message from the last UnlockResult

--// Helpers
--
-- Same shapes as BedUi and InventoryUi, so every panel stays visually identical.

-- Properties first, Parent last: every write happens while the instance is
-- still outside the tree, so the engine lays the panel out once at the end
-- rather than on each assignment.
local function make(className, props)
	local instance = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil

	for key, value in pairs(props) do
		instance[key] = value
	end

	instance.Parent = parent
	return instance
end

local function round(instance, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius), Parent = instance })
	return instance
end

local function label(props)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.TextColor3 = props.TextColor3 or Theme.TEXT
	props.TextSize = props.TextSize or 14
	props.Font = props.Font or Enum.Font.Gotham
	return make("TextLabel", props)
end

local function button(props)
	props.BorderSizePixel = 0
	props.TextColor3 = props.TextColor3 or Theme.TEXT
	props.TextSize = props.TextSize or 14
	props.Font = props.Font or Enum.Font.GothamBold
	props.AutoButtonColor = true
	return make("TextButton", props)
end

-- Driven by MAX_RARITY, so adding a sixth tier needs no UI change.
local function rarityStars(rarity)
	return string.rep("*", rarity) .. string.rep("-", StoryData.MAX_RARITY - rarity)
end

local function heldCount(storyId)
	return counts[storyId] or 0
end

--// Screen

local screenGui = make("ScreenGui", {
	Name = "QuestUi",
	-- Essential: the default destroys this on every respawn, which would leave
	-- every cached reference pointing at a destroyed instance and silently break
	-- all further updates.
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Created here, by the consumer, so it always exists before QuestInteraction can
-- fire it. Two LocalScripts cannot call each other directly.
local openRequest = make("BindableEvent", { Name = "OpenRequest", Parent = screenGui })

local panel = round(make("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(DESIGN_WIDTH, DESIGN_HEIGHT),
	BackgroundColor3 = Theme.PANEL_BG,
	BackgroundTransparency = 0.05,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}), 12)

local panelScale = make("UIScale", { Parent = panel })

-- Scales about the panel's own centre because its AnchorPoint is (0.5, 0.5), so
-- shrinking never pushes it off screen.
local function updateScale()
	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)

	if viewport.X <= 0 or viewport.Y <= 0 then
		return -- one frame during camera setup
	end

	local scale = math.min(
		(viewport.X * VIEWPORT_MARGIN_X) / DESIGN_WIDTH,
		(viewport.Y * VIEWPORT_MARGIN_Y) / DESIGN_HEIGHT,
		1
	)

	panelScale.Scale = math.max(scale, MIN_SCALE)
end

--// Header

label({
	Name = "Title",
	Position = UDim2.fromOffset(PADDING, PADDING),
	Size = UDim2.fromOffset(300, HEADER_HEIGHT),
	Text = "NPC model",
	TextSize = 16,
	TextColor3 = Theme.TEXT_MUTED,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = panel,
})

local moneyLabel = label({
	Name = "Money",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -(PADDING + 44), 0, PADDING),
	Size = UDim2.fromOffset(220, HEADER_HEIGHT),
	Text = "",
	TextSize = 16,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Right,
	Parent = panel,
})

local closeButton = round(button({
	Name = "CloseButton",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -PADDING, 0, PADDING),
	Size = UDim2.fromOffset(34, 34),
	BackgroundColor3 = Theme.SLOT_BG,
	Text = "X",
	TextColor3 = Theme.DANGER,
	TextSize = 20,
	Parent = panel,
}), 8)

--// Left column -- the NPC preview
--
-- A ViewportFrame with its own camera and a clone of the real NPC, so the panel
-- shows whatever the NPC actually is today and picks up a proper model for free
-- once one replaces the placeholder Part.

local npcFrame = round(make("ViewportFrame", {
	Name = "NpcPreview",
	Position = UDim2.fromOffset(PADDING, BODY_Y),
	Size = UDim2.fromOffset(NPC_WIDTH, BODY_HEIGHT),
	BackgroundColor3 = Theme.SLOT_BG,
	BorderSizePixel = 0,
	Ambient = Color3.fromRGB(200, 200, 200),
	LightColor = Color3.fromRGB(255, 255, 255),
	Parent = panel,
}), 10)

local npcWorld = make("WorldModel", { Name = "World", Parent = npcFrame })
local npcCamera = make("Camera", { Parent = npcFrame })
npcFrame.CurrentCamera = npcCamera

local npcModel = nil
local npcSpin = 0

local function buildNpcPreview()
	if npcModel then
		return
	end

	local source = CollectionService:GetTagged(QuestConfig.NPC_TAG)[1]
	if not source then
		return -- NPCs stream in with the plots; try again next open
	end

	npcModel = source:Clone()

	-- Handles both shapes on purpose: the NPC is a placeholder Part today, and
	-- swapping in a rigged Model later should not need this code touched.
	local extent
	if npcModel:IsA("BasePart") then
		npcModel.Anchored = true
		extent = npcModel.Size.Magnitude
	else
		extent = npcModel:GetExtentsSize().Magnitude
	end

	npcModel.Parent = npcWorld
	npcModel:PivotTo(CFrame.new())

	-- Framed off the subject's own size, so a taller model still fits without
	-- retuning these numbers.
	npcCamera.CFrame = CFrame.new(Vector3.new(0, 0, extent * 1.6), Vector3.new())
end

-- Only runs while the panel is open. A viewport spinning behind a closed panel
-- is frame cost for nothing.
local spinConnection = nil

local function startSpin()
	if spinConnection then
		return
	end

	spinConnection = RunService.RenderStepped:Connect(function(delta)
		if not npcModel then
			buildNpcPreview()
			return
		end

		npcSpin += delta * NPC_SPIN_SPEED
		-- PivotTo rather than .CFrame, so this works for a Model too.
		npcModel:PivotTo(CFrame.Angles(0, npcSpin, 0))
	end)
end

local function stopSpin()
	if spinConnection then
		spinConnection:Disconnect()
		spinConnection = nil
	end
end

--// Right column -- shared container

local rightPanel = round(make("Frame", {
	Name = "Right",
	Position = UDim2.fromOffset(RIGHT_X, BODY_Y),
	Size = UDim2.fromOffset(RIGHT_WIDTH, BODY_HEIGHT),
	BackgroundColor3 = Theme.HEADER_BG,
	BorderSizePixel = 0,
	Parent = panel,
}), 10)

make("UIPadding", {
	PaddingLeft = UDim.new(0, PADDING),
	PaddingRight = UDim.new(0, PADDING),
	PaddingTop = UDim.new(0, PADDING),
	PaddingBottom = UDim.new(0, PADDING),
	Parent = rightPanel,
})

--// View A -- the level list

local listView = make("ScrollingFrame", {
	Name = "ListView",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	-- UIListLayout drives the canvas height, so rows can be added without any
	-- manual CanvasSize arithmetic.
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = rightPanel,
})

make("UIListLayout", {
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, GAP),
	Parent = listView,
})

-- Styling seam for a list row.
local function createLevelRow(entry)
	local row = round(button({
		Name = "Level" .. entry.Level,
		Size = UDim2.new(1, -10, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.SLOT_BG,
		Text = "",
		LayoutOrder = entry.Level,
		AutoButtonColor = false,
		Parent = listView,
	}), 24)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 20),
		PaddingRight = UDim.new(0, 20),
		Parent = row,
	})

	local name = label({
		Name = "LevelName",
		Size = UDim2.fromScale(0.3, 1),
		Text = ("Lvl.%d"):format(entry.Level),
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	local state = label({
		Name = "State",
		Position = UDim2.fromScale(0.3, 0),
		Size = UDim2.fromScale(0.7, 1),
		Text = "",
		TextColor3 = Theme.TEXT_MUTED,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	return { row = row, name = name, state = state, level = entry.Level }
end

local levelRows = {}

-- Rows are built here but wired further down, once render() exists. Splitting a
-- click across two connections would leave the redraw depending on connection
-- order, which is not a thing to rely on.
for _, entry in ipairs(StoryData.Levels) do
	table.insert(levelRows, createLevelRow(entry))
end

--// View B -- the quest detail

local detailView = make("Frame", {
	Name = "DetailView",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = rightPanel,
})

local detailTitle = round(label({
	Name = "DetailTitle",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromScale(0.5, 0),
	Size = UDim2.fromOffset(280, 40),
	BackgroundTransparency = 0,
	BackgroundColor3 = Theme.SLOT_BG,
	Text = "",
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	Parent = detailView,
}), 8)

local COLUMN_Y = 40 + GAP
local COLUMN_HEIGHT = BODY_HEIGHT - (PADDING * 2) - COLUMN_Y - FOOTER_HEIGHT - GAP

local function createColumn(name, xScale)
	local column = round(make("Frame", {
		Name = name,
		Position = UDim2.new(xScale, xScale == 0 and 0 or GAP / 2, 0, COLUMN_Y),
		Size = UDim2.new(0.5, -GAP / 2, 0, COLUMN_HEIGHT),
		BackgroundColor3 = Theme.SLOT_BG,
		BorderSizePixel = 0,
		Parent = detailView,
	}), 8)

	label({
		Name = "Caption",
		Size = UDim2.new(1, 0, 0, 30),
		Text = name,
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		Parent = column,
	})

	local list = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(8, 32),
		Size = UDim2.new(1, -16, 1, -40),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = column,
	})

	make("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
		Parent = list,
	})

	return list
end

local payList = createColumn("สิ่งที่ต้องจ่าย", 0)
local rewardList = createColumn("สิ่งที่จะได้", 0.5)

-- Styling seam for a cost line.
local function createCostRow(order, caption, value, satisfied)
	local row = round(make("Frame", {
		Name = "Cost" .. order,
		Size = UDim2.new(1, 0, 0, COST_ROW_HEIGHT),
		BackgroundColor3 = Theme.FIELD_BG,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = payList,
	}), 4)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		Parent = row,
	})

	label({
		Name = "Caption",
		Size = UDim2.fromScale(0.68, 1),
		Text = caption,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	label({
		Name = "Value",
		Position = UDim2.fromScale(0.68, 0),
		Size = UDim2.fromScale(0.32, 1),
		Text = value,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextColor3 = satisfied and Theme.TEXT or Theme.DANGER,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	return row
end

-- Styling seam for a reward line.
local function createRewardRow(order, story)
	local row = round(make("Frame", {
		Name = story.Id,
		Size = UDim2.new(1, 0, 0, COST_ROW_HEIGHT),
		BackgroundColor3 = Theme.FIELD_BG,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = rewardList,
	}), 4)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		Parent = row,
	})

	label({
		Name = "StoryName",
		Size = UDim2.fromScale(0.62, 1),
		Text = story.Name,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	label({
		Name = "Rarity",
		Position = UDim2.fromScale(0.62, 0),
		Size = UDim2.fromScale(0.38, 1),
		Text = ("%s  $%d"):format(rarityStars(story.Rarity), story.BaseReward),
		TextSize = 12,
		TextColor3 = Theme.rarityColor(story.Rarity),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	return row
end

--// Footer

local statusLabel = label({
	Name = "Status",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -(FOOTER_HEIGHT + 4)),
	Size = UDim2.new(1, 0, 0, 20),
	Text = "",
	TextColor3 = Theme.TEXT_MUTED,
	TextSize = 12,
	Parent = detailView,
})

local cancelButton = round(button({
	Name = "CancelButton",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(0.5, -GAP / 2, 1, 0),
	Size = UDim2.fromOffset(160, FOOTER_HEIGHT),
	BackgroundColor3 = Theme.FIELD_BG,
	Text = "ยกเลิก",
	Parent = detailView,
}), 8)

local confirmButton = round(button({
	Name = "ConfirmButton",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0.5, GAP / 2, 1, 0),
	Size = UDim2.fromOffset(160, FOOTER_HEIGHT),
	BackgroundColor3 = Theme.ACCENT,
	Text = "ยืนยัน",
	Parent = detailView,
}), 8)

--// Rendering
--
-- One pass draws whichever view is active. Every number comes from leaderstats,
-- StoryData or the inventory counts -- nothing is cached, so the panel cannot
-- drift from the server.

local function clearList(list)
	for _, child in ipairs(list:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function renderList()
	local level = storyLevel.Value

	for _, entry in ipairs(levelRows) do
		local isCurrent = entry.level == level and level <= StoryData.MAX_LEVEL
		local isDone = entry.level < level

		entry.row.BackgroundColor3 = isCurrent and Theme.SLOT_SELECTED_BG or Theme.SLOT_BG
		entry.row.AutoButtonColor = isCurrent
		entry.name.TextColor3 = (isCurrent or isDone) and Theme.TEXT or Theme.TEXT_MUTED

		if isDone then
			entry.state.Text = "เสร็จแล้ว"
			entry.state.TextColor3 = Theme.TEXT_MUTED
		elseif isCurrent then
			entry.state.Text = (entry.level >= StoryData.MAX_LEVEL) and "เลเวลสูงสุด" or "กดเพื่อดูเควส"
			entry.state.TextColor3 = Theme.ACCENT
		else
			entry.state.Text = "ยังไม่ถึง"
			entry.state.TextColor3 = Theme.TEXT_MUTED
		end
	end
end

local function renderDetail()
	local questLevel = activeQuestLevel
	local nextLevel = questLevel + 1
	local cost = StoryData.getUnlockCost(nextLevel) or 0

	detailTitle.Text = ("Lvl.%d"):format(questLevel)

	clearList(payList)
	clearList(rewardList)

	local moneyOk = money.Value >= cost
	createCostRow(1, "เงิน", ("$%d / $%d"):format(money.Value, cost), moneyOk)

	-- One row per required rarity. Named after whichever candidate Story the
	-- player already holds, so the line reads as the thing they will hand over.
	local missing = {}
	local order = 2

	for _, group in ipairs(StoryData.getQuestRequirement(questLevel)) do
		local held = nil
		for _, storyId in ipairs(group.StoryIds) do
			if heldCount(storyId) > 0 then
				held = storyId
				break
			end
		end

		local shown = StoryData.getStoryById(held or group.StoryIds[1])
		createCostRow(
			order,
			("%s  %s"):format(rarityStars(group.Rarity), shown and shown.Name or "?"),
			held and "1 / 1" or "0 / 1",
			held ~= nil
		)

		if not held then
			table.insert(missing, group.Rarity)
		end
		order += 1
	end

	for index, story in ipairs(StoryData.getLevelStories(nextLevel)) do
		createRewardRow(index, story)
	end

	local ready = moneyOk and #missing == 0

	confirmButton.BackgroundColor3 = ready and Theme.ACCENT or Theme.FIELD_BG
	confirmButton.AutoButtonColor = ready

	if statusOverride then
		statusLabel.Text = statusOverride
	elseif ready then
		statusLabel.Text = "พร้อมส่งเควส"
	elseif not moneyOk and #missing > 0 then
		statusLabel.Text = ("ขาดเงิน $%d และ story ดาว %s")
			:format(cost - money.Value, table.concat(missing, ", "))
	elseif not moneyOk then
		statusLabel.Text = ("ขาดเงินอีก $%d"):format(cost - money.Value)
	else
		statusLabel.Text = ("ยังขาด story ดาว %s"):format(table.concat(missing, ", "))
	end
end

local function render()
	moneyLabel.Text = ("$%d  |  Lvl.%d/%d"):format(money.Value, storyLevel.Value, StoryData.MAX_LEVEL)

	-- The quest for a level only exists while the player is on it. Finishing one
	-- advances the level, which is what drops us back to the list.
	if activeQuestLevel and activeQuestLevel ~= storyLevel.Value then
		activeQuestLevel = nil
	end

	local inDetail = activeQuestLevel ~= nil
	listView.Visible = not inDetail
	detailView.Visible = inDetail

	if inDetail then
		renderDetail()
	else
		renderList()
	end
end

-- Wired here rather than at creation so render() already exists: one handler
-- per row that both opens the quest and redraws.
for _, entry in ipairs(levelRows) do
	entry.row.Activated:Connect(function()
		-- Only the level the player is ON has a quest, and the last level has no
		-- next one to buy. render() re-checks this too, but guarding here stops a
		-- stale click from opening a detail view that should not exist.
		if entry.level ~= storyLevel.Value or entry.level >= StoryData.MAX_LEVEL then
			return
		end

		statusOverride = nil
		activeQuestLevel = entry.level
		render()
	end)
end

local function setOpen(open)
	panel.Visible = open

	if open then
		statusOverride = nil
		activeQuestLevel = nil
		updateScale()
		buildNpcPreview()
		startSpin()
		render()
	else
		stopSpin()
	end
end

--// Server sync

money.Changed:Connect(function()
	if panel.Visible then
		render()
	end
end)

storyLevel.Changed:Connect(function()
	if panel.Visible then
		render()
	end
end)

InventoryUpdated.OnClientEvent:Connect(function(storyId, newCount)
	counts[storyId] = newCount

	if panel.Visible then
		render()
	end
end)

task.spawn(function()
	local snapshot = GetInventory:InvokeServer()
	if type(snapshot) ~= "table" then
		return -- throttled, or the server declined
	end

	for storyId, count in pairs(snapshot) do
		-- Only fill gaps: a live update that already arrived is newer than this
		-- snapshot.
		if counts[storyId] == nil then
			counts[storyId] = count
		end
	end

	if panel.Visible then
		render()
	end
end)

UnlockResult.OnClientEvent:Connect(function(ok, reason, serverMoney, missingRarities)
	if ok then
		statusOverride = "ปลดล็อกสำเร็จ story ใหม่จะเริ่มไหลมาบนสายพาน"
	elseif reason == "insufficient_funds" then
		local cost = StoryData.getUnlockCost(storyLevel.Value + 1) or 0
		statusOverride = ("Server เห็นเงิน $%d ต้องใช้ $%d"):format(serverMoney or 0, cost)

		-- The client's replica can be edited locally without ever reaching the
		-- server (Studio's Client-context command bar does exactly that). Saying
		-- so here turns a panel that appears to contradict itself into an answer.
		if serverMoney and serverMoney ~= money.Value then
			statusOverride ..= (" (ฝั่งคุณแสดง $%d ซึ่งไม่ตรงกับ server)"):format(money.Value)
		end
	elseif reason == "missing_stories" then
		statusOverride = ("ยังขาด story ดาว %s"):format(table.concat(missingRarities or {}, ", "))
	elseif reason == "max_level" then
		statusOverride = "อยู่เลเวลสูงสุดแล้ว"
	elseif reason == "no_plot" then
		statusOverride = "ต้องจอง plot ก่อน"
	else
		statusOverride = "ปลดล็อกไม่สำเร็จ"
	end

	if panel.Visible then
		render()
	end
end)

--// Input

openRequest.Event:Connect(function()
	setOpen(true)
end)

closeButton.Activated:Connect(function()
	setOpen(false)
end)

cancelButton.Activated:Connect(function()
	statusOverride = nil
	activeQuestLevel = nil
	render()
end)

confirmButton.Activated:Connect(function()
	-- No arguments: the server reads this player's own leaderstats and inventory
	-- and looks the cost up itself. The gating below is courtesy, not security.
	if not activeQuestLevel or activeQuestLevel ~= storyLevel.Value then
		return
	end

	statusOverride = nil
	UnlockLevel:FireServer()
end)

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		updateScale()
	end
end)

if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

updateScale()
