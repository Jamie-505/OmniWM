-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

return {
    options = {
        rooms = {
            type = "strings",
            title = "Rooms",
            default = {},
            maxLength = 64,
        },
        artist = {
            type = "boolean",
            title = "Show artist in bar",
            default = false,
        },
    },
}
