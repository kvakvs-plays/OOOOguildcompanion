local addonName, ns = ...

---@class OOOOEmoji An emoji of the guild
---@field id integer Emoji id: the index in `ns.emojiSprites`
---@field name string Name on Discord; also the key in the saved settings
---@field aliases string[] Other spellings which show the emoji, from EmojiAliases.lua
---@field caseSensitive boolean true when chat must have the exact letter case, from EmojiOptions.lua

---@class OOOOEmojiModule
---@field list OOOOEmoji[]|nil Built on first use
local emojiModule = {}
ns.emoji = emojiModule

local ATLAS_ROOT = "Interface\\AddOns\\" .. addonName .. "\\Icons\\Emoji\\Atlas"

---All emoji of the guild, sorted by name without regard to case. The standard emoji of Discord are not in
---this list: they have no settings of their own.
---@return OOOOEmoji[]
function emojiModule:GetAll()
  if self.list then
    return self.list
  end

  local list = {} ---@type OOOOEmoji[]
  for id, sprite in ipairs(ns.emojiSprites) do
    if not sprite.standard then
      local options = ns.emojiOptions[sprite.name]
      list[#list + 1] = {
        id = id,
        caseSensitive = (options and options.caseSensitive) or false,
        name = sprite.name,
        aliases = ns.emojiAliases[sprite.name] or {},
      }
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

---Returns the atlas page of an emoji and the place of the emoji on it, for a texture object.
---@param id integer Emoji id
---@return string texture Path of the atlas page
---@return number left Texture coordinates of the emoji on the page, 0 to 1
---@return number right
---@return number top
---@return number bottom
function emojiModule:GetTexture(id)
  local sprite, atlas = ns.emojiSprites[id], ns.emojiAtlas
  return ATLAS_ROOT .. sprite.page .. ".png",
    sprite.x / atlas.size, (sprite.x + atlas.cell) / atlas.size,
    sprite.y / atlas.size, (sprite.y + atlas.cell) / atlas.size
end

---Returns the escape sequence which shows an emoji inside a text.
---@param id integer Emoji id
---@param size integer Side of the emoji in the text, in pixels
---@return string
function emojiModule:GetEscape(id, size)
  local sprite, atlas = ns.emojiSprites[id], ns.emojiAtlas
  -- |Tpath:height:width:offsetX:offsetY:textureWidth:textureHeight:left:right:top:bottom|t, in pixels
  return "|T" .. ATLAS_ROOT .. sprite.page .. ".png:" .. size .. ":" .. size .. ":0:0:" .. atlas.size .. ":"
    .. atlas.size .. ":" .. sprite.x .. ":" .. (sprite.x + atlas.cell) .. ":" .. sprite.y .. ":"
    .. (sprite.y + atlas.cell) .. "|t"
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
  ns.emojiChat:ResetCache()
end
