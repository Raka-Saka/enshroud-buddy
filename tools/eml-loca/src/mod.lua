-- The game's text in every language it ships: loca/<language>.jsonl, one {"id": tag hash, "t": text} per line,
-- plus loca/languages.txt. tools/build_db.py matches the English text the other exports carry to its tag.
-- job.txt (written by tools/export_loca.py): no job file, do nothing.
if not loader.features.export or not io.exists("job.txt") then
	return
end

local function json_str(s)
	s = tostring(s):gsub('[%c"\\]', function(c)
		local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
		return map[c] or string.format("\\u%04x", c:byte())
	end)
	return '"' .. s .. '"'
end

local ok, err = pcall(function()
	local loca = game.assets.get_resources_by_type("keen::LocaTagCollectionResource")[1].data
	local names = {}
	for _, lang in ipairs(loca.languages) do
		local name = tostring(lang.language)
		local buf = game.assets.get_content(game.guid.from_content_hash(lang.data.hash)):read_data()
		local rows = {}
		for _, tag in ipairs(buf:read_resource("keen::LocaTagCollectionResourceData").tags) do
			if tag.text and tag.text ~= "" then
				rows[#rows + 1] = '{"id":' .. string.format('"%08x"', tag.id.value) .. ',"t":' .. json_str(tag.text) .. "}"
			end
		end
		io.export("loca/" .. name .. ".jsonl", table.concat(rows, "\n"))
		names[#names + 1] = name .. "\t" .. #rows
	end
	io.export("loca/languages.txt", table.concat(names, "\n"))
	print("loca: " .. #names .. " languages")
end)
if not ok then
	print("loca failed: " .. tostring(err))
end
