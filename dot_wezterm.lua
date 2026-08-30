local wezterm = require 'wezterm'
local config = {}

-- wezterm.gui is not available to the mux server, so take care to
-- do something reasonable when this config is evaluated by the mux
function get_appearance()
  if wezterm.gui then
    return wezterm.gui.get_appearance()
  end
  return 'Dark'
end

function scheme_for_appearance(appearance)
  if appearance:find 'Dark' then
    return 'Builtin Solarized Dark'
  else
    return 'Vs Code Light+ (Gogh)'
  end
end

config.color_scheme = scheme_for_appearance(get_appearance())

config.default_prog = { 'pwsh.exe', '-NoLogo' }

config.enable_kitty_keyboard = true

config.launch_menu = {
  {
    label = 'SSH: oracle0_proxy',
    args = { 'ssh.exe', 'oracle0_proxy' },
  },  
  {
    label = 'SSH: oracle1_proxy',
    args = { 'ssh.exe', 'oracle1_proxy' },
  },
}

return config