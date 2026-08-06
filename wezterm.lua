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

-- Tab bar styled to match Tokyo Night (tmux status bar sits just below it)
config.use_fancy_tab_bar = false
config.tab_max_width = 32
config.colors = {
  tab_bar = {
    background = '#16161e',
    active_tab = { bg_color = '#7aa2f7', fg_color = '#16161e', intensity = 'Bold' },
    inactive_tab = { bg_color = '#292e42', fg_color = '#a9b1d6' },
    inactive_tab_hover = { bg_color = '#3b4261', fg_color = '#c0caf5' },
    new_tab = { bg_color = '#16161e', fg_color = '#565f89' },
    new_tab_hover = { bg_color = '#292e42', fg_color = '#c0caf5' },
  },
}
config.window_padding = { left = 8, right = 8, top = 4, bottom = 0 }

-- Finally, return the configuration to wezterm:
return config

