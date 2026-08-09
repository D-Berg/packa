local function fields(value, allowed, where)
  if value == nil then
    return
  end

  if type(value) ~= "table" then
    error(where .. " must be a table")
  end

  for key in pairs(value) do
    if not allowed[key] then
      error("unknown field " .. where .. "." .. tostring(key))
    end
  end
end

local function strings(value, where)
  if value == nil then
    return {}
  end

  if type(value) ~= "table" then
    error(where .. " must be a list")
  end

  for index, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      error(where .. "[" .. index .. "] must be a non-empty string")
    end
  end

  return value
end

local config = __packa_config
fields(config, {
  version = true,
  packages = true,
  install = true,
  dev_shell = true,
  dev_shells = true,
}, "config")

if config.version ~= 1 then
  error("config.version must be 1")
end

fields(config.install, {
  build_from_source = true,
}, "config.install")

if config.install
    and config.install.build_from_source ~= nil
    and type(config.install.build_from_source) ~= "boolean"
then
  error("config.install.build_from_source must be a boolean")
end

local selected = config.dev_shell
if __packa_shell_name ~= nil then
  if type(config.dev_shells) ~= "table" then
    error("config.dev_shells must be a table")
  end

  selected = config.dev_shells[__packa_shell_name]
  if selected == nil then
    error("unknown development shell " .. __packa_shell_name)
  end
elseif selected == nil and type(config.dev_shells) == "table" then
  selected = config.dev_shells.default
end

local environment = {}
if selected ~= nil then
  fields(selected, {
    packages = true,
    environment = true,
  }, "dev_shell")

  if selected.environment ~= nil then
    if type(selected.environment) ~= "table" then
      error("dev_shell.environment must be a table")
    end

    for key, value in pairs(selected.environment) do
      if type(key) ~= "string" or type(value) ~= "string" then
        error("development shell environment keys and values must be strings")
      end

      environment[#environment + 1] = { key, value }
    end
  end
end

return {
  packages = strings(config.packages, "config.packages"),
  shell_packages = strings(selected and selected.packages, "dev_shell.packages"),
  environment = environment,
  build_from_source = config.install and config.install.build_from_source or false,
}
