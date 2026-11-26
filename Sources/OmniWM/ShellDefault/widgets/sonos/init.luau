-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")
local media = require("../lib/media")
local sonos = require("../lib/sonos")

function render(ctx)
    local settings = ctx.data.settings or {}
    local m = sonos.state(ctx, settings.rooms, settings.artist == true)
    if not m then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = look.scale(ctx)
    local props = { onClick = ui.popout, onRightClick = m.toggle, help = m.help,
        look.barGlyph(ctx, { name = m.symbol, size = 14 * scale }) }
    if not ctx.data.bar.style.vertical then
        props[#props + 1] = look.text{ text = m.text, size = 13 * scale, maxWidth = 160 * scale }
    end
    return look.bar(ctx, props)
end

function popout(ctx)
    local settings = ctx.data.settings or {}
    local m = sonos.model(ctx, settings.rooms)
    local rows = { w = look.width + 28, look.heading("Sonos") }
    if m then
        rows[#rows + 1] = media.content(ctx, false, nil, m)
        if m.volume then
            rows[#rows + 1] = sonos.level(ctx, nil, m)
        end
        if m.rooms then
            rows[#rows + 1] = sonos.rooms(ctx, nil, m)
        end
    else
        rows[#rows + 1] = look.group{ w = look.width,
            look.text{ text = omniwm.l10n("Nothing is playing"), size = 13, color = "secondaryForeground" } }
    end
    return look.panel(ctx, rows)
end
