-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return {
    options = {
        title = {
            type = "boolean",
            title = "Show title",
            default = true,
        },
        artist = {
            type = "boolean",
            title = "Show artist",
            default = false,
        },
        album = {
            type = "boolean",
            title = "Show album",
            default = false,
        },
        time = {
            type = "boolean",
            title = "Show playback time",
            default = false,
        },
        maxWidth = {
            type = "number",
            title = "Maximum title width",
            default = 160,
            min = 40,
            max = 1000,
            step = 10,
        },
    },
}
