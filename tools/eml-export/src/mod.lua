-- Export game data for the companion app (export only, never patches).
-- Run: emm run --export -g <game dir> --export-directory <dir>
-- Lua errors that escape abort emm with a non-unwinding panic, so everything runs under pcall.
if not loader.features.export or io.exists("skip.txt") then
	return -- skip.txt: tools/export_poi.py is running batches
end

local function json_str(s)
	if s == nil then
		return "null"
	end
	s = tostring(s):gsub('[%c"\\]', function(c)
		local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
		return map[c] or string.format("\\u%04x", c:byte())
	end)
	return '"' .. s .. '"'
end

local function json_obj(fields)
	local parts = {}
	for _, kv in ipairs(fields) do
		local v = kv[2]
		if type(v) == "number" then
			v = tostring(v)
		elseif type(v) == "table" then
			local arr = {}
			for _, x in ipairs(v) do
				arr[#arr + 1] = json_str(x)
			end
			v = "[" .. table.concat(arr, ",") .. "]"
		else
			v = json_str(v)
		end
		parts[#parts + 1] = json_str(kv[1]) .. ":" .. v
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function english()
	local loca = game.assets.get_resources_by_type("keen::LocaTagCollectionResource")[1].data
	local ref = loca.keenglishData
	for _, lang in ipairs(loca.languages) do
		if lang.language == "En_Us" then
			ref = lang.data
		end
	end
	local buf = game.assets.get_content(game.guid.from_content_hash(ref.hash)):read_data()
	local dict = {}
	for _, tag in ipairs(buf:read_resource("keen::LocaTagCollectionResourceData").tags) do
		dict[tag.id.value] = tag.text
	end
	return dict
end

local function run()
	local en = english()
	local function text(ref)
		local ok, h = pcall(game.guid.hash, ref)
		return ok and en[h] or nil
	end

	local types = {}
	for _, t in ipairs(game.assets.get_resource_types()) do
		types[#types + 1] = t.qualified_name or t.name
	end
	table.sort(types)
	io.export("resource_types.txt", table.concat(types, "\n"))

	local rows, failed = {}, 0
	local registry = game.assets.get_resources_by_type("keen::ItemRegistryResource")[1].data
	for _, ref in ipairs(registry.itemRefs) do
		local ok, row = pcall(function()
			local d = game.assets.get_resource(ref, "keen::ItemInfo").data
			local cats = {}
			for _, c in ipairs(d.collectionInfo.categories) do
				cats[#cats + 1] = string.format("%08x", c.value)
			end
			return json_obj({
				{ "item_id", string.format("%08x", d.itemId.value) },
				{ "guid", tostring(d.objectId) },
				{ "debug_name", d.debugName },
				{ "name", text(d.name) },
				{ "caption", text(d.caption) },
				{ "description", text(d.description) },
				{ "lore", text(d.lore) },
				{ "acquisition_hint", text(d.acquisitionHint) },
				{ "category", tostring(d.category) },
				{ "rarity", tostring(d.rarity) },
				{ "max_stack", d.maxStackSize },
				{ "collection_categories", cats },
			})
		end)
		if ok then
			rows[#rows + 1] = row
		else
			failed = failed + 1
			if failed <= 5 then
				print("item failed: " .. tostring(row))
			end
		end
	end
	io.export("items.jsonl", table.concat(rows, "\n"))
	print("exported " .. #rows .. " items, " .. failed .. " failed, " .. #types .. " resource types")

	local function hex(k)
		return string.format("%08x", k.value)
	end

	-- workshops (crafting stations), npcs (artisans) and crafting props (station upgrades)
	local wr = game.assets.get_resources_by_type("keen::WorkshopRegistryResource")[1].data
	local ws = {}
	local function add_workshop(kind, w)
		ws[#ws + 1] = json_obj({
			{ "kind", kind },
			{ "workshop_id", hex(w.workshopId) },
			{ "name", en[w.name.value] },
			{ "item_id", hex(w.item) },
		})
	end
	for _, w in ipairs(wr.workshops) do
		add_workshop("station", w)
	end
	for _, w in ipairs(wr.npcs) do
		add_workshop("npc", w)
	end
	for _, p in ipairs(wr.craftingProps) do
		ws[#ws + 1] = json_obj({
			{ "kind", "prop" },
			{ "workshop_id", hex(p.craftingPropId) },
			{ "name", en[p.name.value] },
			{ "item_id", hex(p.item) },
			{ "prop_index", p.craftingPropIndex },
		})
	end
	io.export("workshops.jsonl", table.concat(ws, "\n"))

	-- recipes: inputs are "item_id:count" or "cat:<category id>:count"; outputs "item_id:count"
	local rr = game.assets.get_resources_by_type("keen::RecipeRegistryResource")[1].data
	local cats = {}
	for _, c in ipairs(rr.inputCategories) do
		local members = {}
		for _, it in ipairs(c.items) do
			members[#members + 1] = hex(it.itemId)
		end
		cats[#cats + 1] = json_obj({ { "category_id", hex(c.inputCategoryId) }, { "items", members } })
	end
	io.export("recipe_categories.jsonl", table.concat(cats, "\n"))

	local recipes = {}
	for _, r in ipairs(rr.recipes) do
		local ok, row = pcall(function()
			local inputs, outputs, props = {}, {}, {}
			for _, i in ipairs(r.input) do
				if i.itemStack.count > 0 then
					inputs[#inputs + 1] = hex(i.itemStack.item) .. ":" .. i.itemStack.count
				end
				if i.inputItemCategory.count > 0 then
					inputs[#inputs + 1] = "cat:" .. hex(i.inputItemCategory.category) .. ":" .. i.inputItemCategory.count
				end
			end
			for _, o in ipairs(r.output) do
				outputs[#outputs + 1] = hex(o.item) .. ":" .. o.count
			end
			for _, p in ipairs(r.requiredProps) do
				props[#props + 1] = hex(p)
			end
			return json_obj({
				{ "recipe_id", hex(r.recipeId) },
				{ "debug_name", r.debugName },
				{ "name", text(r.recipeName) },
				{ "workshop_id", hex(r.workshopId) },
				{ "inputs", inputs },
				{ "outputs", outputs },
				{ "required_props", props },
				{ "duration_ns", tostring(r.craftingDuration.value) },
				{ "level", r.level },
				{ "knowledge_query", hex(r.knowledgeRequirement.knowledgeOrQueryId) },
			})
		end)
		if ok then
			recipes[#recipes + 1] = row
		elseif #recipes == 0 then
			print("recipe failed: " .. tostring(row))
		end
	end
	io.export("recipes.jsonl", table.concat(recipes, "\n"))
	print("exported " .. #recipes .. " recipes, " .. #ws .. " workshops/npcs/props, " .. #cats .. " input categories")

	-- journal: item sets (collectible sets with hints), lore documents, quests.
	-- Nested arrays are written as JSON strings inside arrays, decoded by tools/build_db.py.
	local jr = game.assets.get_resources_by_type("keen::JournalRegistryResource")[1].data
	local sets = {}
	for _, cat in ipairs(jr.itemSetCategories) do
		for _, s in ipairs(cat.entries) do
			local entries = {}
			for _, e in ipairs(s.entries) do
				local hints = {}
				for _, h in ipairs(e.hints) do
					hints[#hints + 1] = json_obj({
						{ "objective", en[h.objective.value] },
						{ "hint", en[h.hintDescription.value] },
						{ "marker", en[h.mapMarkerReference.value] },
						{ "level", h.recommendedLevel },
					})
				end
				entries[#entries + 1] = json_obj({
					{ "item_id", hex(e.itemId) },
					{ "hints", hints },
					{ "done", hex(e.completionKnowledgeQuery.knowledgeOrQueryId) },
					{ "done_type", tostring(e.completionKnowledgeQuery.type) },
				})
			end
			sets[#sets + 1] = json_obj({
				{ "category", en[cat.categoryName.value] },
				{ "set_id", hex(s.setId) },
				{ "name", en[s.setName.value] },
				{ "entries", entries },
			})
		end
	end
	io.export("item_sets.jsonl", table.concat(sets, "\n"))

	local function collection(c, extra)
		local entries = {}
		for _, e in ipairs(c.entries) do
			entries[#entries + 1] = json_obj({
				{ "name", en[e.name.value] },
				{ "text", en[e.text.value] },
				{ "marker", en[e.mapMarkerReference.value] },
				{ "level", e.recommendedLevel },
				{ "seen", hex(e.knowledgeRequirement.knowledgeOrQueryId) },
				{ "seen_type", tostring(e.knowledgeRequirement.type) },
				{ "done", hex(e.completionRequirement.knowledgeOrQueryId) },
				{ "done_type", tostring(e.completionRequirement.type) },
			})
		end
		local fields = {
			{ "entry_id", hex(c.entryId) },
			{ "name", en[c.name.value] },
			{ "lore_category", en[c.loreCategory.value] or hex(c.loreCategory) },
			{ "tutorial", tostring(c.isTutorial) },
			{ "entries", entries },
		}
		for _, kv in ipairs(extra or {}) do
			fields[#fields + 1] = kv
		end
		return json_obj(fields)
	end
	local lore = {}
	for _, c in ipairs(jr.collections) do
		lore[#lore + 1] = collection(c)
	end
	io.export("lore.jsonl", table.concat(lore, "\n"))
	local quests = {}
	for _, q in ipairs(jr.quests) do
		local rewards = {}
		for _, r in ipairs(q.rewards) do
			rewards[#rewards + 1] = hex(r.itemId)
		end
		quests[#quests + 1] = collection(q, {
			{ "main", tostring(q.isMainQuest) },
			{ "type", tostring(q.type) },
			{ "source", tostring(q.source) },
			{ "rewards", rewards },
		})
	end
	io.export("quests.jsonl", table.concat(quests, "\n"))
	print("exported " .. #sets .. " item sets, " .. #lore .. " lore collections, " .. #quests .. " quests")

	-- skill tree: nodes with effect values ("<loca text>=<value>"), links between nodes
	local st = game.assets.get_resources_by_type("keen::SkillTreeResource")[1].data
	local nodes = {}
	for _, n in ipairs(st.nodes) do
		local values, links = {}, {}
		for _, v in ipairs(n.uiValues) do
			values[#values + 1] = tostring(en[v.locaId.value] or hex(v.locaId)) .. "=" .. tostring(v.value)
		end
		for _, l in ipairs(n.outgoingLinks) do
			links[#links + 1] = hex(l)
		end
		-- the skill's numbers: "simple" (fixed) and "scaled" (x skill level) impact configs, as JSON text
		local config = {}
		for _, kind in ipairs({ "simple", "scaled" }) do
			for _, c in ipairs(n.configValues[kind]) do
				config[#config + 1] = kind .. "|" .. tostring(c.type) .. "|" .. tostring(c.value)
			end
		end
		nodes[#nodes + 1] = json_obj({
			{ "node_id", hex(n.id) },
			{ "name", en[n.name.value] },
			{ "description", en[n.description.value] },
			{ "per_level", en[n.perLevelEffectDescription.value] },
			{ "type", tostring(n.type) },
			{ "class", tostring(n.classAlignment) },
			{ "max_level", n.maxLevel },
			{ "costs", n.costs },
			{ "x", n.uiPosition.x },
			{ "y", n.uiPosition.y },
			{ "values", values },
			{ "config", config },
			{ "links", links },
		})
	end
	local links = {}
	for _, l in ipairs(st.links) do
		links[#links + 1] = json_obj({ { "link_id", hex(l.id) }, { "from", hex(l.sourceNode) }, { "to", hex(l.targetNode) } })
	end
	io.export("skills.jsonl", table.concat(nodes, "\n"))
	io.export("skill_links.jsonl", table.concat(links, "\n"))
	print("exported " .. #nodes .. " skill nodes, " .. #links .. " links")

	-- knowledge queries: what unlocks recipes, map markers and journal entries
	local qdb = game.assets.get_resources_by_type("keen::GameKnowledgeQueryResourceDb")[1].data
	local qs = {}
	for _, q in ipairs(qdb.queries) do
		local actions = {}
		for _, a in ipairs(q.actions) do
			actions[#actions + 1] = json_obj({
				{ "type", tostring(a.type) },
				{ "name", a.name },
				{ "ref", hex(a.query.knowledgeOrQueryId) },
				{ "ref_type", tostring(a.query.type) },
				{ "value", a.query.compareValue },
				{ "op", tostring(a.query.compareOperator) },
				{ "invert", tostring(a.invertResult) },
			})
		end
		qs[#qs + 1] = json_obj({
			{ "query_id", hex(q.queryId.id) },
			{ "name", q.name },
			{ "type", tostring(q.type) },
			{ "invert", tostring(q.invertResult) },
			{ "knowledge_id", tostring(q.knowledgeId.value or q.knowledgeId) },
			{ "op", tostring(q.compareOperation) },
			{ "value", q.compareValue },
			{ "actions", actions },
		})
	end
	for _, q in ipairs(qdb.runtimeQueries) do
		qs[#qs + 1] = json_obj({
			{ "query_id", hex(q.queryId.id) },
			{ "name", q.name },
			{ "type", tostring(q.type) },
			{ "runtime", "true" },
			{ "item_id", hex(q.itemId) },
			{ "npc_action", tostring(q.npcActionType) },
			{ "npc_id", hex(q.npcId) },
			{ "prop", hex(q.craftingProp) },
			{ "op", tostring(q.compareOperation) },
			{ "value", q.compareValue },
		})
	end
	io.export("knowledge_queries.jsonl", table.concat(qs, "\n"))
	print("exported " .. #qs .. " knowledge queries")

	-- item stats: slot, level range, damage/armor split, perks, displayed values and food buffs
	local function nz(obj, fields)
		local out = {}
		for _, f in ipairs(fields) do
			local v = obj[f]
			if v and v ~= 0 then
				out[#out + 1] = f .. "=" .. string.format("%.3g", v)
			end
		end
		return out
	end
	local function ui(values)
		local out = {}
		for _, v in ipairs(values) do
			out[#out + 1] = string.format("%s=%d%s%s", tostring(en[v.locaId.value] or hex(v.locaId)), v.value,
				v.isScaled and ("*" .. string.format("%.3g", v.scaleData.scaleFactor)) or "",
				tostring(v.valueFormat) == "Percentage" and "%" or "")
		end
		return out
	end
	local stats, sfail = {}, 0
	for _, ref in ipairs(registry.itemRefs) do
		local okS, row = pcall(function()
			local d = game.assets.get_resource(ref, "keen::ItemInfo").data
			local perks = {}
			for _, p in ipairs(d.perkReferences) do
				local pr = game.assets.get_resource(p, "keen::Perk")
				if pr then
					perks[#perks + 1] = tostring(text(pr.data.name) or pr.data.debugName)
				end
			end
			return json_obj({
				{ "item_id", string.format("%08x", d.itemId.value) },
				{ "slot", tostring(d.equipment.slot) },
				{ "alignment", tostring(d.itemClassAlignment) },
				{ "min_level", d.itemLevelRange.minLevel },
				{ "max_level", d.itemLevelRange.maxLevel },
				{ "damage", d.damageSetup.isSet and nz(d.damageSetup.distribution, { "physicalCutDamage", "physicalPierceDamage",
					"physicalBluntDamage", "magicalFireDamage", "magicalIceDamage", "magicalFogDamage",
					"magicalLightningDamage", "healing", "poisonDamage" }) or {} },
				{ "dmg_mod", d.damageSetup.isSet and d.damageSetup.dmgMod or 0 },
				{ "speed_mod", d.damageSetup.isSet and d.damageSetup.speedMod or 0 },
				{ "armor", d.armorSetup.isSet and nz(d.armorSetup.distribution, { "physical", "blunt", "pierce", "cut",
					"magical", "fire", "ice", "fog", "lightning" }) or {} },
				{ "block", d.blockSetup.isSet and d.blockSetup.quality or 0 },
				{ "comfort", d.comfortSetup.isSet and d.comfortSetup.comfortAmount or 0 },
				{ "perks", perks },
				{ "values", ui(d.uiValues) },
				{ "buffs", ui(d.uiBuffValues) },
			})
		end)
		if okS then
			stats[#stats + 1] = row
		else
			sfail = sfail + 1
			if sfail <= 3 then
				print("stats failed: " .. tostring(row))
			end
		end
	end
	io.export("item_stats.jsonl", table.concat(stats, "\n"))
	print("exported " .. #stats .. " item stats, " .. sfail .. " failed")

	-- loot: what can drop from which chest
	local function tags(list)
		local out = {}
		for _, t in ipairs(list) do
			out[#out + 1] = string.format("%08x:%d:%.3g", t.tagId.value, t.groupIndex, t.weight)
		end
		return out
	end
	local function modifier(m)
		local r = {}
		for _, v in ipairs(m.rarities) do
			r[#r + 1] = tostring(v.mode) .. "=" .. string.format("%.3g", v.value)
		end
		return string.format("level %s=%.3g offset %s=%.3g [%.3g..%.3g] rarities %s", tostring(m.level.mode), m.level.value,
			tostring(m.levelOffset.mode), m.levelOffset.value, m.levelOffsetRangeMin, m.levelOffsetRangeMax, table.concat(r, ","))
	end
	local function labels(group, out)
		for _, l in ipairs(group.labels) do
			out[#out + 1] = string.format("%08x:%d", l.tagId.value, l.groupIndex)
		end
		for _, g in ipairs(group.childGroups) do
			labels(g, out)
		end
		return out
	end
	local lootable = game.assets.get_resources_by_type("keen::LootableItemsResource")[1].data
	local li = {}
	for _, it in ipairs(lootable.items) do
		li[#li + 1] = json_obj({
			{ "item_id", hex(it.itemId) },
			{ "rarities", tostring(it.rarities) },
			{ "stack_min", it.stackSizeMin },
			{ "stack_max", it.stackSizeMax },
			{ "shufflebag", tostring(it.shufflebagType) },
			{ "labels", labels(it.labelGroups, {}) },
		})
	end
	io.export("loot_items.jsonl", table.concat(li, "\n"))
	local drops = {}
	for i = 1, 5 do drops[i] = string.format("%.4g", lootable.globalRarityDropRates[i]) end
	local ls = {}
	for _, s in ipairs(game.assets.get_resources_by_type("keen::DefaultLootLabelCollectionResource")[1].data.lootSettings) do
		ls[#ls + 1] = json_obj({ { "id", hex(s.id) }, { "modifier", modifier(s.modifier) }, { "tags", tags(s.tags) } })
	end
	io.export("loot_settings.jsonl", table.concat(ls, "\n"))
	local chestT = {}
	for _, t in ipairs(game.assets.get_resources_by_type("keen::ecs::TemplateResource")) do
		local row
		for _, comp in ipairs(t.data.components) do
			if comp.type == "keen::ecs::RandomLootContainer" then
				row = row or {}
				row.settings = hex(comp.value.defaultLabelsId)
			elseif comp.type == "keen::ecs::RandomLoot" then
				row = row or {}
				local okh, h = pcall(game.guid.hash, comp.value.defaultLabels)
				row.labels = okh and string.format("%08x", h) or ""
				local okf, f = pcall(game.guid.hash, comp.value.forwardSpecialItemLabels)
				row.special = okf and string.format("%08x", f) or ""
			elseif comp.type == "keen::ecs::RandomLootSlotCount" then
				row = row or {}
				row.slots = comp.value.slotsMin .. "-" .. comp.value.slotsMax
			end
		end
		if row then
			chestT[#chestT + 1] = json_obj({ { "template", t.data.name }, { "settings", row.settings or "" }, { "labels", row.labels or "" },
				{ "special_labels", row.special or "" }, { "slots", row.slots or "" } })
		end
	end
	io.export("loot_containers.jsonl", table.concat(chestT, "\n"))
	local scene = game.assets.get_resources_by_type("keen::SceneRandomLootResource")
	local special, nodes = {}, 0
	for _, sr in ipairs(scene) do
		for _, sp in ipairs(sr.data.specialItems) do
			local b = sp.lootContainerBoundingBox
			special[#special + 1] = json_obj({
				{ "item_id", hex(sp.itemId) },
				{ "amount", sp.amount },
				{ "quest", tostring(sp.isQuestItem) },
				{ "candidates", #sp.lootContainerCandidates },
				{ "box", string.format("%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z) },
			})
		end
		nodes = nodes + #sr.data.lootContainer
	end
	io.export("loot_special.jsonl", table.concat(special, "\n"))
	print(string.format("exported loot: %d lootable items, %d settings, %d container templates, %d special items, %d scene loot nodes, rarity drop rates %s",
		#li, #ls, #chestT, #special, nodes, table.concat(drops, "/")))

	-- skill tree art: node frames per state, Spark ring, background, and the skill icons (<name>_unlocked etc.)
	local art = 0
	for _, r in ipairs(game.assets.get_resources_by_type("keen::UiTextureResource")) do
		local nm = r.data.debugName or ""
		local low = nm:lower()
		if low:find("^skillnode") or low:find("^skilltree") or low:find("_unlocked$") or low:find("_out_of_reach$") then
			local okA = pcall(function()
				local d = r.data
				local buf = game.assets.get_content(game.guid.from_content_hash(d.data.hash)):read_data()
				io.export("skilltree/" .. nm .. ".png", image.encode(image.decode_texture(buf, d.format, d.size.x, d.size.y, 0), "png"))
			end)
			if okA then art = art + 1 end
		end
	end
	print("exported " .. art .. " skill tree textures")

	-- balancing: Shroud time, Flame levels, cold and oxygen
	local bal = game.assets.get_resources_by_type("keen::BalancingTable")[1].data
	local function arr(a) local o = {} for _, v in ipairs(a) do o[#o + 1] = v end return o end
	local zones = {}
	for _, v in ipairs(bal.buildzoneSizesPerAltarLevel) do zones[#zones + 1] = string.format("%.0f", v.x) end
	io.export("balancing.json", json_obj({
		{ "flame_level_max", bal.flameLevelMax },
		{ "altar_level_max", bal.altarLevelMax },
		{ "player_level_max", bal.playerLevelMax },
		{ "fog_base_s", bal.playerBaseFogResistance },
		{ "fog_per_flame_s", bal.playerFogResistancePerFlameLevel },
		{ "body_heat", bal.playerBaseBodyHeat },
		{ "oxygen_s", bal.playerBaseOxygen },
		{ "freeze_factor", bal.freezeDurationFactor },
		{ "freeze_offset", bal.freezeDurationOffset },
		{ "no_freeze_flame_level", bal.disableFreezingBaseLevel },
		{ "altars_per_flame", arr(bal.altarsPerFlameLevel) },
		{ "skill_points_per_level", bal.skillPointsPerLevel },
		{ "skill_point_unlocks", (function()
			local out = {}
			for _, sp in ipairs(game.assets.get_resources_by_type("keen::GameKnowledgeResource")[1].data.skillPoints) do
				out[#out + 1] = string.format("%08x:%d", sp.knowledgeId.id.value, sp.amount)
			end
			return out
		end)() },
		{ "buildzone_per_altar", zones },
	}))
	-- Shroud zones: level and bounding box per scene
	local fz = {}
	for _, r in ipairs(game.assets.get_resources_by_type("keen::FogVoxelMappingResource")) do
		for _, m in ipairs(r.data.mapping) do
			local b = m.boundingBox
			fz[#fz + 1] = json_obj({
				{ "scene", tostring(r.guid) }, { "type", tostring(m.type) }, { "level", m.level },
				{ "removal", string.format("%08x", m.removalId.value) },
				{ "box", string.format("%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z) },
			})
		end
	end
	io.export("fog_zones.jsonl", table.concat(fz, string.char(10)))
	print("exported balancing and " .. #fz .. " fog zones")

	-- temperature: the world's 3D grid (the one big VoxelTemperatureResource) flattened to two 2D maps,
	-- the highest value in each column and the mean of its non-zero values, as binary PGM images
	for _, r in ipairs(game.assets.get_resources_by_type("keen::VoxelTemperatureResource")) do
		local d = r.data
		local sx, sy, sz = d.sizeInVoxels.x, d.sizeInVoxels.y, d.sizeInVoxels.z
		if sx * sy * sz > 1000 then
			local v = d.voxelData
			local mx, mean = {}, {}
			for z = 0, sz - 1 do
				for x = 0, sx - 1 do
					local best, sum, n = 0, 0, 0
					for y = 0, sy - 1 do
						local t = v[1 + x + sx * (y + sy * z)]
						if t > best then best = t end
						if t > 0 then sum, n = sum + t, n + 1 end
					end
					mx[#mx + 1] = string.char(best)
					mean[#mean + 1] = string.char(n > 0 and math.floor(sum / n) or 0)
				end
			end
			local head = string.format("P5\n%d %d\n255\n", sx, sz)
			io.export("cold_max.pgm", head .. table.concat(mx))
			io.export("cold_mean.pgm", head .. table.concat(mean))
			io.export("cold.json", json_obj({
				{ "origin", string.format("%.0f,%.0f,%.0f", d.worldOrigin.x, d.worldOrigin.y, d.worldOrigin.z) },
				{ "size", string.format("%.0f,%.0f,%.0f", d.worldSize.x, d.worldSize.y, d.worldSize.z) },
				{ "voxels", string.format("%d,%d,%d", sx, sy, sz) },
			}))
			print(string.format("exported temperature grid %dx%dx%d", sx, sy, sz))
		end
	end

	-- world map textures (UiMapResource parts): base height, gradients, 10x10 detail and fog-zone tiles
	local map = game.assets.get_resources_by_type("keen::UiMapResource")[1]
	local tex = game.assets.get_resource_parts(map.guid, "keen::UiTextureResource")
	local index = {}
	for _, t in ipairs(tex) do
		local d = t.data
		local okt, errt = pcall(function()
			local buf = game.assets.get_content(game.guid.from_content_hash(d.data.hash)):read_data()
			local img = image.decode_texture(buf, d.format, d.size.x, d.size.y, 0)
			io.export(string.format("map/part_%03d.png", t.part), image.encode(img, "png"))
		end)
		index[#index + 1] = string.format("%d\t%s\t%dx%d\t%s", t.part, d.debugName, d.size.x, d.size.y, okt and "ok" or tostring(errt))
	end
	io.export("map/index.tsv", table.concat(index, "\n"))
	print("exported " .. #tex .. " map textures (" .. map.data.tileCount.x .. "x" .. map.data.tileCount.y .. " tiles)")
end

local ok, err = pcall(run)
if not ok then
	print("export failed: " .. tostring(err))
end
