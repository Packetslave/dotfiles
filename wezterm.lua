-- Pull in the wezterm API
local wezterm = require 'wezterm'

-- This will hold the configuration.
local config = wezterm.config_builder()

-- This is where you actually apply your config choices.

-- For example, changing the initial geometry for new windows:
config.initial_cols = 120
config.initial_rows = 28

-- or, changing the font size and color scheme.
config.font = wezterm.font("Monaspace Argon NF", {weight="Medium", stretch="Normal", style="Normal"})
config.font_size = 16
config.line_height = 1.2
config.color_scheme = 'Tokyo Night'

-- No macOS title bar; window is still resizable and AeroSpace handles placement
config.window_decorations = "RESIZE"

-- Tab bar: black background, fixed-width tabs
config.use_fancy_tab_bar = false
local TAB_WIDTH = 24
config.tab_max_width = TAB_WIDTH
config.colors = {
  tab_bar = {
    background = '#000000',
    active_tab = { bg_color = '#ffffff', fg_color = '#000000', intensity = 'Bold' },
    inactive_tab = { bg_color = '#3b4261', fg_color = '#c0caf5' },
    inactive_tab_hover = { bg_color = '#414868', fg_color = '#c0caf5' },
    new_tab = { bg_color = '#000000', fg_color = '#565f89' },
    new_tab_hover = { bg_color = '#292e42', fg_color = '#c0caf5' },
  },
}

-- Pad/truncate every tab title to the same width
wezterm.on('format-tab-title', function(tab)
  local title = tab.tab_title
  if title == nil or #title == 0 then
    title = tab.active_pane.title
  end
  title = string.format('%d: %s', tab.tab_index + 1, title)
  local inner = TAB_WIDTH - 2  -- leave a space of padding on each side
  if wezterm.column_width(title) > inner then
    title = wezterm.truncate_right(title, inner - 1) .. '…'
  else
    title = title .. string.rep(' ', inner - wezterm.column_width(title))
  end
  return ' ' .. title .. ' '
end)
config.window_padding = { left = 8, right = 8, top = 4, bottom = 0 }

-- Finally, return the configuration to wezterm:
return config

