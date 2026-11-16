local addonName, ns = ...

---@class OOOOEmoji
---@field name string File name without the extension; also the key in the saved settings
---@field trigger string Text which shows the emoji, like ":Kek:"
---@field texture string Path of the 64x64 texture

---@class OOOOEmojiModule
---@field list OOOOEmoji[]|nil Built on first use
local emojiModule = {}
ns.emoji = emojiModule

local TEXTURE_ROOT = "Interface\\AddOns\\" .. addonName .. "\\Icons\\Emoji\\"

---All emoji shipped with the addon, sorted by name without regard to case.
---@return OOOOEmoji[]
function emojiModule:GetAll()
  if self.list then
    return self.list
  end

  local guildIds = {}
  for guildId in pairs(ns.emojiIndex) do
    guildIds[#guildIds + 1] = guildId
  end
  table.sort(guildIds)

  local list = {} ---@type OOOOEmoji[]
  local seen = {} ---@type table<string, boolean>
  for _, guildId in ipairs(guildIds) do
    for _, name in ipairs(ns.emojiIndex[guildId]) do
      -- The trigger must be unique, so the first guild wins when two guilds have one name
      if not seen[name] then
        seen[name] = true
        list[#list + 1] = {
          name = name,
          trigger = ":" .. name .. ":",
          texture = TEXTURE_ROOT .. guildId .. "\\" .. name .. ".png",
        }
      end
    end
  end
  table.sort(list, function(a, b)
    local lowerA, lowerB = a.name:lower(), b.name:lower()
    if lowerA ~= lowerB then
      return lowerA < lowerB
    end
    return a.name < b.name
  end)

  self.list = list
  return list
end

---@param name string Emoji name
---@return boolean enabled false when the user turned this emoji off
function emojiModule:IsEnabled(name)
  return not ns.db.profile.emoji.disabled[name]
end

---@param name string Emoji name
---@param enabled boolean
function emojiModule:SetEnabled(name, enabled)
  -- Only the disabled ones are stored, so a new emoji is enabled without a migration
  ns.db.profile.emoji.disabled[name] = (not enabled) or nil
end
