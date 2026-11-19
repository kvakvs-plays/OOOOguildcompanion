local addonName, ns = ...

-- This file uses no WoW API, so the host tests can load it (Tests/sync_probe.lua).

---Routes a command text by its first word to a handler; an unknown word prints the usage text.
---@class OOOODispatcher
---@field prefix string What the user types before the word, for the usage text ("/oooo")
---@field handlers table<string, fun(rest: string)> Word in lower case -> handler
---@field help string[] Usage lines, in the order of registration
---@field default (fun())|nil What the prefix alone does; without it the prefix alone prints the usage text
---@field defaultHelp string|nil Usage line of the prefix alone, without the prefix: "open the window"
local Dispatcher = {}
Dispatcher.__index = Dispatcher

---Prints one line for the user. Core.lua replaces it with the addon's chat output; host tests capture it.
---@param text string
function ns.print(text)
  print(text)
end

---Makes a dispatcher for the commands that follow `prefix`.
---@param prefix string
---@return OOOODispatcher
function ns.newDispatcher(prefix)
  return setmetatable({ prefix = prefix, handlers = {}, help = {} }, Dispatcher)
end

---Adds a command. A repeated word is a programming error.
---@param word string First word of the command, matched in any letter case
---@param help string Usage line without the prefix: "opt - open the settings window"
---@param handler fun(rest: string) Receives the trimmed text after the word, in its original letter case
function Dispatcher:Register(word, help, handler)
  word = word:lower()
  assert(not self.handlers[word], "command registered twice: " .. word)
  self.handlers[word] = handler
  self.help[#self.help + 1] = help
end

---Sets what the prefix alone does, without a word after it.
---@param help string Usage line without the prefix: "open or close the addon window"
---@param handler fun()
function Dispatcher:SetDefault(help, handler)
  self.default, self.defaultHelp = handler, help
end

---Calls the handler of the first word of `input`, or prints the usage text when no handler has that word.
---An input without a word calls the default handler when there is one.
---@param input any Text after the prefix; anything that is not a string counts as empty
---@return boolean handled false when the usage text was printed
function Dispatcher:Dispatch(input)
  local word, rest = (type(input) == "string" and input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  if word == "" and self.default then
    self.default()
    return true
  end
  local handler = self.handlers[word:lower()]
  if not handler then
    self:PrintUsage()
    return false
  end
  handler(rest)
  return true
end

---Prints one usage line per registered command.
function Dispatcher:PrintUsage()
  ns.print("Usage:")
  if self.defaultHelp then
    ns.print("  " .. self.prefix .. " - " .. self.defaultHelp)
  end
  for _, help in ipairs(self.help) do
    ns.print("  " .. self.prefix .. " " .. help)
  end
end

---Commands after `/oooo`
ns.slash = ns.newDispatcher("/oooo")
---Commands after `/oooo sync`
ns.syncSlash = ns.newDispatcher("/oooo sync")

ns.slash:Register("sync", "sync <command> - shared database commands", function(rest)
  ns.syncSlash:Dispatch(rest)
end)
