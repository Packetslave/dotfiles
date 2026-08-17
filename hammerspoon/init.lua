-- Chime when the 1Password CLI authorization prompt appears.
-- The prompt window is titled exactly "1Password"; the main window is
-- "All Accounts — All Items — 1Password", so match on the bare title.
hs.window.filter.default:setAppFilter("1Password", { allowRoles = "*" })

-- global on purpose: a local would be garbage-collected and the
-- subscription silently dropped
opPrompt = hs.window.filter.new("1Password")
  :subscribe(hs.window.filter.windowCreated, function(w)
    if w:title() == "1Password" then
      hs.sound.getByName("Ping"):play()
    end
  end)
