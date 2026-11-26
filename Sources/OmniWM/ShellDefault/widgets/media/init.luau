-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")
local media = require("../lib/media")
local audio = require("../lib/audio")

function render(ctx)
    local m = media.bar(ctx)
    if not m then
        return ui.box{ w = 0, h = 0 }
    end
    local behaviour = { onClick = ui.popout, onRightClick = m.toggle, help = m.help }
    local button = look.mediaBar and look.mediaBar(ctx, m)
    if not button then
        local scale = look.scale(ctx)
        local props = table.clone(behaviour)
        props[1] = look.barGlyph(ctx, { name = m.symbol, size = 14 * scale })
        if not ctx.data.bar.style.vertical then
            if m.text ~= "" then
                props[#props + 1] = look.text{ text = m.text, size = 13 * scale, maxWidth = m.maxWidth * scale }
            end
            if m.timeText then
                props[#props + 1] = look.text{ text = m.timeText, style = "mono", size = 12 * scale,
                    color = "secondaryForeground" }
            end
        end
        button = look.bar(ctx, props)
    end
    for key, value in behaviour do
        button[key] = value
    end
    return button
end

function popout(ctx)
    local m = media.model(ctx)
    if m then
        m.audio = audio.state(ctx)
    end
    return look.mediaPanel and look.mediaPanel(ctx, m)
        or look.panel(ctx, { w = look.width + 28, look.heading(omniwm.l10n("Media")), media.content(ctx, false, nil, m) })
end
