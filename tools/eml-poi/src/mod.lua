-- Map points of interest from the world scene's entity chunks, one batch per run.
-- Columns: category, template, label, extra, x, y, z, visible query, completed query, chunk area levels,
-- more (key=value;...: fish=<spawn table guid>, radius, tp=<teleporter id>><target id>, boss, puzzle=<type>,
-- water=<dispenser type>, locked, updraft, spawns=<template>, for labels mt=<marker type>, dungeon=<id>,
-- and the entity's own values: lv=<level>, tpid / tpto=<teleporter ids> (see spawn_info), f_<flag>=<raw>).
-- Categories beyond label/lore/chest: fishing, teleport, boss, puzzle, water_source, locked, spawner, updraft.
-- Also census/<first>.tsv (every entity: template, cell x, cell y, count), inside/<first>.tsv (every other
-- entity in the far north-west corner, where the Hollow Halls' insides are: template, x, y, z), and with the
-- first batch templates.tsv (name, guid, component types), fish_tables.tsv, marker_types.tsv.
-- Category "trigger": any entity whose spawn data sets knowledge (SceneKnowledgeTrigger); extra = the ids.
-- A Shroud Root plant uses one to grant its first-time skill point.
-- Also writes gather/<first>.tsv: template, item ids it gives, map cell x, cell y (16 px of the 1280 grid,
-- 128 m), how many in that cell, the chunk's top area level. Plants, bushes, stones, bait and mining nodes.
-- job.txt (written by tools/export_poi.py): "<first chunk> <last chunk>". No job file: do nothing.
-- Batches exist because touching every entity of 1,609 chunks exhausts mlua's 1M reference slots.
if not loader.features.export or not io.exists("job.txt") then
	return
end

local first, last = io.read_to_string("job.txt"):match("(%d+)%s+(%d+)")
first, last = tonumber(first), tonumber(last)

local loca = game.assets.get_resources_by_type("keen::LocaTagCollectionResource")[1].data
local ref = loca.keenglishData
for _, lang in ipairs(loca.languages) do
	if lang.language == "En_Us" then ref = lang.data end
end
local en = {}
for _, tag in ipairs(game.assets.get_content(game.guid.from_content_hash(ref.hash)):read_data()
	:read_resource("keen::LocaTagCollectionResourceData").tags) do
	en[tag.id.value] = tag.text
end
local function text(r)
	local ok, h = pcall(game.guid.hash, r)
	return ok and en[h] or nil
end
local function clean(s)
	return (tostring(s or ""):gsub("[\t\r\n]", " "))
end
local function q(d)
	return string.format("%s:%08x", tostring(d.type), d.knowledgeOrQueryId.value)
end

-- what a gather template gives: DefaultInventory stacks, a PickupItem, or ResourceNodePickupDrops
local itemOf = {}
for _, r in ipairs(game.assets.get_resources_by_type("keen::ItemInfo")) do
	itemOf[tostring(r.guid)] = string.format("%08x", r.data.itemId.value)
end
local inventories = {}
for _, r in ipairs(game.assets.get_resources_by_type("keen::ecs::DefaultInventoryResource")) do
	inventories[tostring(r.guid)] = r
end
local function stacks(group, out)
	for _, st in ipairs(group.stacks) do
		out[string.format("%08x", st.item.value)] = true
	end
	for _, g in ipairs(group.groups) do
		stacks(g, out)
	end
end
local gives = {}
local function hk(v)
	local ok, s = pcall(function() return string.format("%08x", v.value) end)
	return ok and s or ""
end

-- interesting templates by guid: category, label, extra, visible query, completed query, more (key=value;...)
local wanted, names, comps = {}, {}, {}
for _, t in ipairs(game.assets.get_resources_by_type("keen::ecs::TemplateResource")) do
	names[tostring(t.guid)] = t.data.name
end
for _, t in ipairs(game.assets.get_resources_by_type("keen::ecs::TemplateResource")) do
	local name = t.data.name
	local row
	local items = {}
	-- other things worth a map pin, by component; the first one names the category of a template
	-- that has no row of its own (a label stays a label and gets these in "more")
	local more, cat2, label2, types = {}, nil, nil, {}
	local function add(cat, kv, label)
		more[#more + 1] = kv
		cat2 = cat2 or cat
		label2 = label2 or label
	end
	for _, comp in ipairs(t.data.components) do
		local ty = comp.type
		types[#types + 1] = ty
		local v = comp.value
		if ty == "keen::ecs::FishingSpot" then
			add("fishing", "fish=" .. tostring(v.spawnTable) .. ";radius=" .. string.format("%.1f", v.radius))
		elseif ty == "keen::ecs::TeleportZoneConnection" then
			add("teleport", "tp=" .. hk(v.teleporterId) .. ">" .. hk(v.targetTeleporterId))
		elseif ty == "keen::ecs::TeleportZone" then
			add("teleport", "tpzone=" .. tostring(v.zoneTag))
		elseif ty == "keen::ecs::BossHealthBar" then
			add("boss", "boss=1", text(v.displayName))
		elseif ty == "keen::ecs::Boss" then
			add("boss", "boss=1")
		elseif ty == "keen::ecs::PuzzleCompletionNotifier" then
			add("puzzle", "puzzle=" .. tostring(v.type))
		elseif ty == "keen::ecs::WaterDispenser" then
			add("water_source", "water=" .. tostring(v.dispenserType))
		elseif ty == "keen::ecs::GliderUpstreamZone" then
			add("updraft", "updraft=1")
		elseif ty == "keen::ecs::InteractionKnowledgeLock" then
			add("locked", "locked=1")
		elseif ty == "keen::ecs::MapMarker" then
			local ok, mh = pcall(game.guid.hash, v.markerType)
			more[#more + 1] = "mt=" .. (ok and string.format("%08x", mh) or tostring(v.markerType))
				.. ";dungeon=" .. hk(v.dungeonId) .. ";bigdungeon=" .. tostring(v.isInBigDungeon)
		elseif ty == "keen::ecs::BasicSpawnerComponent" or ty == "keen::ecs::TriggerSpawner"
			or ty == "keen::ecs::TriggerBoxMultiSpawner" then
			local et = names[tostring(v.entityTemplate)]
			if et then add("spawner", "spawns=" .. clean(et)) end
		elseif ty == "keen::ecs::RandomSpawner" then
			add("spawner", "rs=1")  -- what it spawns: links.tsv
		end
		if ty == "keen::ecs::DefaultInventory" then
			local inv = inventories[tostring(comp.value.defaultInventory)]
			if inv then stacks(inv.data.rootGroup, items) end
		elseif ty == "keen::ecs::PickupItem" then
			local id = itemOf[tostring(comp.value.item)]
			if id then items[id] = true end
		elseif ty == "keen::ecs::ResourceNodePickupDrops" then
			for _, dr in ipairs(comp.value.drops) do
				local id = itemOf[tostring(dr.item)]
				if id then items[id] = true end
			end
		end
		if ty == "keen::ecs::MapMarker" then
			row = row or { cat = "label", label = text(comp.value.markerId) }
		elseif ty == "keen::ecs::LoreReading" then
			row = { cat = "lore", label = text(comp.value.entryName), extra = text(comp.value.unlockMapMarker) }
		end
	end
	if not row and (name == "Prop_Tower_Beacon" or name:find("^Prop_Ancient_Dungeon_Beacon")) then
		row = { cat = "beacon", label = "Return Beacon" }
	elseif not row and name:find("^Prop_FlamePower_Restore_Prop_Capsule") then
		row = { cat = "capsule", label = "Hourglass capsule" }
	elseif not row and name == "Zone_OxygenReplenish_AirBubbles" then
		row = { cat = "air", label = "Air bubbles" }
	end
	if not row and name:find("^LootChest_") then
		row = { cat = "chest", label = name:gsub("^LootChest_Random_", ""):gsub("^LootChest_", "") }
	end
	if next(items) and not name:find("^LootChest_") and not name:find("^8kMapLabel") then
		local list = {}
		for id in pairs(items) do list[#list + 1] = id end
		table.sort(list)
		gives[tostring(t.guid)] = table.concat(list, ",")
	end
	if not row and cat2 then
		row = { cat = cat2, label = label2 }
	end
	if row then
		for _, comp in ipairs(t.data.components) do
			if comp.type == "keen::ecs::RuntimeMapMarkerUnlockRequirements" then
				row.visible = q(comp.value.visibleStateQuery)
				row.completed = q(comp.value.completedStateQuery)
			end
		end
		row.name = name
		row.more = table.concat(more, ";")
		wanted[tostring(t.guid)] = row
	end
	comps[#comps + 1] = clean(name) .. "\t" .. tostring(t.guid) .. "\t" .. table.concat(types, ",")
end

-- once, with the first batch: links.tsv, how templates lead to each other and what an enemy leaves:
-- name, guid, then key=value;... spawns=<template>:<weight>,... (RandomSpawner entries, basic/trigger spawners,
-- spawn on destroy, loot entity, sub-entities), drops=<item>:<weight>,... (ResourceNodePickupDrops),
-- dropn=<number of drops>, dropent=<templates dropped>, kill=<knowledge ids set on kill>, killitem=<item>,
-- boss=1, bossname=<English name>. Only templates with any of these.
if first == 1 then
	local links = {}
	local function ref(r)
		local n = names[tostring(r)]
		return n and clean(n):gsub("[,:;=]", "_") or nil
	end
	for _, t in ipairs(game.assets.get_resources_by_type("keen::ecs::TemplateResource")) do
		local kv, spawns, drops, dropent, kill = {}, {}, {}, {}, {}
		for _, comp in ipairs(t.data.components) do
			local ty, v = comp.type, comp.value
			local ok = pcall(function()
				if ty == "keen::ecs::RandomSpawner" then
					for _, e in ipairs(v.spawnEntries) do
						for _, et in ipairs(e.entityTemplates) do
							local n = ref(et)
							if n then spawns[#spawns + 1] = n .. ":" .. string.format("%.2f", e.weight) end
						end
					end
				elseif ty == "keen::ecs::BasicSpawnerComponent" or ty == "keen::ecs::TriggerSpawner"
					or ty == "keen::ecs::TriggerBoxMultiSpawner" then
					local n = ref(v.entityTemplate)
					if n then spawns[#spawns + 1] = n .. ":1" end
				elseif ty == "keen::ecs::SpawnEntityOnDestroy" then
					local n = ref(v.spawnEntity)
					if n then spawns[#spawns + 1] = n .. ":destroy" end
				elseif ty == "keen::ecs::RandomLootEntitySpawner" then
					local n = ref(v.lootEntity)
					if n then spawns[#spawns + 1] = n .. ":loot" end
				elseif ty == "keen::ecs::SubEntities" then
					for _, se in ipairs(v.subEntities) do
						local n = ref(se.templateRef)
						if n then spawns[#spawns + 1] = n .. ":sub" end
					end
				elseif ty == "keen::ecs::ResourceNodePickupDrops" then
					for _, dr in ipairs(v.drops) do
						local id = itemOf[tostring(dr.item)]
						if id then drops[#drops + 1] = id .. ":" .. string.format("%.2f", dr.weight) end
						local n = ref(dr.entity)
						if n then dropent[#dropent + 1] = n end
					end
					local n = ref(v.pickupItemReference)
					if n then dropent[#dropent + 1] = n end
					kv[#kv + 1] = "dropn=" .. tostring(v.numberOfDrops)
				elseif ty == "keen::ecs::KnowledgeTriggerOnKill" then
					local k = v.knowledgeUnlockOperation.knowledgeId.id.value
					if k ~= 0 then kill[#kill + 1] = string.format("%08x", k) end
					local id = itemOf[tostring(v.triggerKnowledge.item)]
					if id then kv[#kv + 1] = "killitem=" .. id end
				elseif ty == "keen::ecs::Boss" then
					kv[#kv + 1] = "boss=1"
				elseif ty == "keen::ecs::BossHealthBar" then
					local n = text(v.displayName)
					if n then kv[#kv + 1] = "bossname=" .. clean(n):gsub("[;=]", " ") end
				end
			end)
			if not ok then kv[#kv + 1] = "err_" .. tostring(ty):gsub("keen::ecs::", "") .. "=1" end
		end
		if #spawns > 0 then table.insert(kv, 1, "spawns=" .. table.concat(spawns, ",")) end
		if #drops > 0 then kv[#kv + 1] = "drops=" .. table.concat(drops, ",") end
		if #dropent > 0 then kv[#kv + 1] = "dropent=" .. table.concat(dropent, ",") end
		if #kill > 0 then kv[#kv + 1] = "kill=" .. table.concat(kill, ",") end
		if #kv > 0 then
			links[#links + 1] = clean(t.data.name) .. "\t" .. tostring(t.guid) .. "\t" .. table.concat(kv, ";")
		end
	end
	table.sort(links)
	-- scene.tsv: the scene's quest items (kind, item id, raw world position x y z, loot container id) and quest
	-- entities (kind, template, x y z, knowledge ids they unlock). WorldPosition is fixed point: raw i64 values.
	local scene = {}
	for _, sr in ipairs(game.assets.get_resources_by_type("keen::SceneResource")) do
		local okq = pcall(function()
			for _, qi in ipairs(sr.data.questItems) do
				local p = qi.transform.position
				scene[#scene + 1] = table.concat({ "item", string.format("%08x", qi.itemId.value), tostring(p.x),
					tostring(p.y), tostring(p.z), string.format("%08x", qi.lootContainerId.value) }, "\t")
			end
		end)
		if not okq then scene[#scene + 1] = "error\tquestItems" end
		local oke = pcall(function()
			for _, qe in ipairs(sr.data.questEntities) do
				local p = qe.transform.position
				local ids = {}
				for _, op in ipairs(qe.unlockOperations) do
					local ok, v = pcall(function() return op.unlockOperation.knowledgeId.id.value end)
					if ok and v ~= 0 then ids[#ids + 1] = string.format("%08x", v) end
				end
				scene[#scene + 1] = table.concat({ "entity", clean(names[tostring(qe.templateGuid)] or tostring(qe.templateGuid)),
					tostring(p.x), tostring(p.y), tostring(p.z), table.concat(ids, ",") }, "\t")
			end
		end)
		if not oke then scene[#scene + 1] = "error\tquestEntities" end
	end
	io.export("scene.tsv", table.concat(scene, "\n"))
	io.export("links.tsv", table.concat(links, "\n"))

	table.sort(comps)
	io.export("templates.tsv", table.concat(comps, "\n"))
	local fish = {}
	for _, r in ipairs(game.assets.get_resources_by_type("keen::fishing::FishSpawnTableResource")) do
		local d = r.data
		local e = {}
		for _, f in ipairs(d.fishEntries) do
			e[#e + 1] = string.format("%08x:%.3f:%s", f.item.value, f.weight, tostring(f.timeFrame))
		end
		local s = {}
		for _, f in ipairs(d.shoeEntries) do
			s[#s + 1] = string.format("%08x:%.3f:%s", f.item.value, f.percentage, tostring(f.timeFrame))
		end
		fish[#fish + 1] = table.concat({ tostring(r.guid), tostring(d.canSpawnTrash),
			string.format("%.3f", d.trashEntry.percentage), table.concat(e, ","), table.concat(s, ",") }, "\t")
	end
	io.export("fish_tables.tsv", table.concat(fish, "\n"))
	local mm = {}
	local reg = game.assets.get_resources_by_type("keen::MapMarkerRegistryResource")[1]
	if reg then
		local m = reg.data.mapMarkers
		for i = 1, #m.keys do
			local v = m.values[i]
			mm[#mm + 1] = table.concat({ hk(m.keys[i]), hk(v.markerId), clean(text(v.typeName) or ""),
				tostring(v.sortingCategory), tostring(v.isFastTravelDestination), tostring(v.showRange),
				tostring(v.canBeFiltered) }, "\t")
		end
	end
	io.export("marker_types.tsv", table.concat(mm, "\n"))
end

local chunks = game.assets.get_resources_by_type("keen::SceneEntityChunkResource")
local rows, inside, census = {}, {}, {}
local cells, cellLevel = {}, {}
-- One entity's own spawn values (entry i of the chunk's spawn data): after the component count (and the
-- first component index when there are some), one u8 per spawnMask flag, in flag order. Level picks the
-- entity's level from the chunk's list; TeleporterId / TeleportTargetId pick loca tags that pair a teleport
-- with where it leads. Other flags come out raw as f_<flag>=<value>.
local function spawn_info(sd, i)
	local e = sd.entries[i]
	if not e then return "" end
	local ind = sd.indices
	local s = e.spawnIndexStart
	local k = s + 2
	if ind[s + 1] > 0 then k = k + 1 end
	local out = {}
	for _, flag in ipairs(e.spawnMask) do
		local v = ind[k]
		k = k + 1
		if flag == "Level" then
			local l = sd.levels[v + 1]
			out[#out + 1] = "lv=" .. tostring(l.level) .. (l.levelOffset ~= 0 and ("+" .. tostring(l.levelOffset)) or "")
		elseif flag == "TeleporterId" or flag == "TeleportTargetId" then
			local r = sd.locaTags[v + 1]
			local ok, h = pcall(game.guid.hash, r)
			out[#out + 1] = (flag == "TeleporterId" and "tpid=" or "tpto=") .. (ok and string.format("%08x", h) or "?")
			local t = text(r)
			if t then out[#out + 1] = (flag == "TeleporterId" and "tpname=" or "tptoname=") .. clean(t):gsub("[;=]", " ") end
		else
			out[#out + 1] = "f_" .. tostring(flag) .. "=" .. tostring(v)
		end
	end
	return table.concat(out, ";")
end

local function pos(lo, hi)
	return (hi * 65536 + lo) / 32768
end
for ci = first, math.min(last, #chunks) do
	local d = chunks[ci].data
	local idx, tname, gidx = {}, {}, {}
	for i, tr in ipairs(d.templates) do
		local w = wanted[tostring(tr)]
		tname[i - 1] = names[tostring(tr)] or ""
		if w then
			idx[i - 1] = w
		end
		if gives[tostring(tr)] then
			gidx[i - 1] = tname[i - 1] .. "\t" .. gives[tostring(tr)]
		end
	end
	-- area levels of this chunk (1..9, like item tiers); a chest uses one of them
	local lv = {}
	for _, l in ipairs(d.spawnData.levels) do
		lv[#lv + 1] = tostring(l.level)
	end
	local levels = table.concat(lv, ",")
	local top = 0
	for _, l in ipairs(d.spawnData.levels) do
		if l.level > top then top = l.level end
	end
	-- per-entity spawn data: entry i belongs to entity i. At indices[start]: component count n, and when n > 0
	-- the first component index (components first .. first + n - 1), then one value per spawnMask flag
	local sd = d.spawnData
	local trig, lnode = {}, {}
	local comps = sd.components
	for k = 1, #comps do
		local c = comps[k]
		if c.type == "keen::ecs::SceneLootNodeId" then
			lnode[k - 1] = string.format("%08x", c.value.id.value)
		elseif c.type == "keen::ecs::SceneKnowledgeTrigger" then
			local ids = {}
			for _, op in ipairs(c.value.knowledgeUnlockOperations) do
				local v = op.unlockOperation.knowledgeId.id.value
				if v ~= 0 then ids[#ids + 1] = string.format("%08x", v) end
			end
			if #ids > 0 then trig[k - 1] = table.concat(ids, ",") end
		end
	end
	if next(trig) then
		local entries, ind, ents = sd.entries, sd.indices, d.entities
		for i = 1, math.min(#entries, #ents) do
			local s = entries[i].spawnIndexStart
			local n = ind[s + 1]
			for j = 0, n - 1 do
				local k = trig[ind[s + 2] + j]
				if k then
					local e = ents[i]
					local t = e.transform
					rows[#rows + 1] = table.concat({
						"trigger", clean(tname[e.templateIndex]), "", k,
						string.format("%.1f", pos(t.positionX0, t.positionX1)),
						string.format("%.1f", pos(t.positionY0, t.positionY1)),
						string.format("%.1f", pos(t.positionZ0, t.positionZ1)),
						"", "", levels,
					}, "\t")
				end
			end
		end
	end
	-- the loot node an entity is (SceneLootNodeId: what special and quest items name as their container)
	local function loot_node(i)
		local e = sd.entries[i]
		if not e or not next(lnode) then return nil end
		local s = e.spawnIndexStart
		local n = sd.indices[s + 1]
		for j = 0, n - 1 do
			local k = lnode[sd.indices[s + 2] + j]
			if k then return k end
		end
	end
	-- every entity: the census (template, 128 m cell, count), gather cells, wanted points, and anything in the
	-- far north-west corner where the game keeps the Hollow Halls' insides (drawn as the halls' layout)
	local ents = d.entities
	for i = 1, #ents do
		local e = ents[i]
		local ti = e.templateIndex
		local t = e.transform
		local x, z = pos(t.positionX0, t.positionX1), pos(t.positionZ0, t.positionZ1)
		local cx, cy = math.floor(x / 256), math.floor((20480 - z) / 256)
		local ck = tname[ti] .. "\t" .. cx .. "\t" .. cy
		census[ck] = (census[ck] or 0) + 1
		local g = gidx[ti]
		if g then
			local key = g .. "\t" .. cx .. "\t" .. cy
			cells[key] = (cells[key] or 0) + 1
			if top > (cellLevel[key] or 0) then cellLevel[key] = top end
		end
		local w = idx[ti]
		if not w and next(lnode) then
			local okn, ln = pcall(loot_node, i)
			if okn and ln then
				rows[#rows + 1] = table.concat({ "lootnode", clean(tname[ti]), "", "",
					string.format("%.1f", x), string.format("%.1f", pos(t.positionY0, t.positionY1)), string.format("%.1f", z),
					"", "", levels, "ln=" .. ln }, "\t")
			end
		end
		if w or (x < 4200 and z > 16000) then
			local y = string.format("%.1f", pos(t.positionY0, t.positionY1))
			-- random spawn points are wanted for their positions, and still part of a hall's layout
			if w and w.cat == "spawner" and (";" .. (w.more or "") .. ";"):find(";rs=1;", 1, true)
				and x < 4200 and z > 16000 then
				inside[#inside + 1] = table.concat({ clean(tname[ti]), string.format("%.1f", x), y,
					string.format("%.1f", z) }, "\t")
			end
			if w then
				local ok, own = pcall(spawn_info, sd, i)
				local more = w.more or ""
				if ok and own ~= "" then more = more == "" and own or (more .. ";" .. own) end
				local okn, ln = pcall(loot_node, i)
				if okn and ln then more = more == "" and ("ln=" .. ln) or (more .. ";ln=" .. ln) end
				rows[#rows + 1] = table.concat({
					w.cat, clean(w.name), clean(w.label), clean(w.extra),
					string.format("%.1f", x), y, string.format("%.1f", z),
					w.visible or "", w.completed or "", levels, more,
				}, "\t")
			else
				inside[#inside + 1] = table.concat({ clean(tname[ti]), string.format("%.1f", x), y,
					string.format("%.1f", z) }, "\t")
			end
		end
	end
end
io.export(string.format("poi/%05d.tsv", first), table.concat(rows, "\n"))
local g = {}
for key, n in pairs(cells) do
	g[#g + 1] = key .. "\t" .. n .. "\t" .. (cellLevel[key] or 0)
end
io.export(string.format("gather/%05d.tsv", first), table.concat(g, "\n"))
local c = {}
for key, n in pairs(census) do
	c[#c + 1] = key .. "\t" .. n
end
io.export(string.format("census/%05d.tsv", first), table.concat(c, "\n"))
io.export(string.format("inside/%05d.tsv", first), table.concat(inside, "\n"))
print(string.format("poi chunks %d-%d of %d: %d points", first, last, #chunks, #rows))
