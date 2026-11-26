-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("./look")

local sonos = {}
local BUNDLE = "com.sonos.macController2"

local function clock(seconds: number): string
    local total = math.max(0, math.floor(seconds))
    local hours, minutes, rest = total // 3600, total % 3600 // 60, total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, rest)
    end
    return string.format("%d:%02d", minutes, rest)
end

local function allowed(room: string, rooms): boolean
    if type(rooms) ~= "table" or #rooms == 0 then
        return true
    end
    for _, wanted in rooms do
        if string.lower(room) == string.lower(wanted) then
            return true
        end
    end
    return false
end

local function listens(group, rooms): boolean
    for _, room in group.rooms do
        if allowed(room, rooms) then
            return true
        end
    end
    return false
end

function sonos.group(ctx, rooms)
    local data = ctx.data.sonos
    if not data then
        return nil, {}
    end
    local shown = {}
    local chosen, playing, paused
    for _, group in data.groups do
        if group.title ~= "" and listens(group, rooms) then
            shown[#shown + 1] = group
            if group.id == ctx.state.sonosRoom then
                chosen = group
            elseif group.playing then
                playing = playing or group
            else
                paused = paused or group
            end
        end
    end
    return chosen or playing or paused, shown
end

function sonos.state(ctx, rooms, withArtist: boolean?)
    local group = sonos.group(ctx, rooms)
    if not group then
        return nil
    end
    local full = if group.artist ~= "" then group.title .. " — " .. group.artist else group.title
    return { title = group.title, artist = group.artist, playing = group.playing, room = group.room,
        text = if withArtist then full else group.title, toggle = "sonos toggle " .. group.id,
        symbol = if group.playing then "hifispeaker.fill" else "pause.fill",
        help = full .. " (" .. group.room .. ")" }
end

function sonos.model(ctx, rooms)
    local group, shown = sonos.group(ctx, rooms)
    if not group then
        return nil
    end
    local id = group.id
    local m = { title = group.title, artist = group.artist, album = group.album, bundle = BUNDLE, app = "Sonos",
        artwork = group.artwork, playing = group.playing, room = group.room,
        playSymbol = if group.playing then "pause.fill" else "play.fill",
        toggle = "sonos toggle " .. id, previous = "sonos previous " .. id, next = "sonos next " .. id,
        open = "sonos open" }
    local duration = group.duration
    local position = group.elapsed or 0
    if group.playing then
        position += math.max(0, ctx.data.seconds - group.sampledAt)
    end
    m.position = math.max(0, position)
    if duration and duration > 0 and group.elapsed ~= nil then
        m.position = math.min(m.position, duration)
        m.duration = duration
        m.fraction = m.position / duration
        m.elapsedText = clock(m.position)
        m.durationText = clock(duration)
        m.seek = function(_, event)
            if event.value and event.phase == "ended" then
                omniwm.run(string.format("sonos seek %s %.0f", id, event.value * duration))
            end
        end
    end
    if group.volume then
        m.volume = { level = group.volume / 100, muted = group.muted == true,
            percent = ctx.format.percent(math.round(group.volume) / 100),
            symbol = if group.muted then "speaker.slash.fill" else "speaker.wave.2.fill",
            mute = "sonos mute " .. id,
            set = function(_, event)
                if event.value and event.phase == "ended" then
                    omniwm.run(string.format("sonos volume %s %.0f", id, event.value * 100))
                end
            end }
    end
    if m.volume and #group.members > 1 then
        m.volume.rooms = {}
        for _, member in group.members do
            if member.volume then
                local room = member.id
                m.volume.rooms[#m.volume.rooms + 1] = { name = member.room, level = member.volume / 100,
                    muted = member.muted == true, mute = "sonos room-mute " .. room,
                    symbol = if member.muted then "speaker.slash.fill" else "speaker.wave.2.fill",
                    percent = ctx.format.percent(math.round(member.volume) / 100),
                    set = function(_, event)
                        if event.value and event.phase == "ended" then
                            omniwm.run(string.format("sonos room-volume %s %.0f", room, event.value * 100))
                        end
                    end }
            end
        end
    end
    local entries = {}
    for _, other in ctx.data.sonos.groups do
        local joined = other.id == id
        local tracked = other.title ~= ""
        for _, member in other.members do
            if allowed(member.room, rooms) then
                local entry = { name = member.room, joined = joined,
                    title = if tracked then other.title else omniwm.l10n("Nothing is playing"),
                    symbol = if other.playing then "speaker.wave.2.fill" elseif tracked then "pause.fill"
                        else "hifispeaker" }
                if not joined then
                    entry.button = "plus"
                    entry.command = "sonos join " .. member.id .. " " .. id
                    if tracked and listens(other, rooms) then
                        local room = other.id
                        entry.select = function(next)
                            next.state.sonosRoom = room
                        end
                    end
                elseif #other.members > 1 then
                    entry.button = "minus"
                    entry.command = "sonos leave " .. member.id
                end
                entries[#entries + 1] = entry
            end
        end
    end
    if #entries > 1 then
        m.rooms = entries
    end
    return m
end

function sonos.rooms(_, width: number?, m)
    width = width or look.width
    local inner = width - 24
    local rows = { w = width, gap = 4, look.heading(omniwm.l10n("Rooms")) }
    for _, room in m.rooms do
        rows[#rows + 1] = ui.row{ w = inner, gap = 8,
            ui.row{ grow = 1, gap = 8, pad = 6, radius = look.radius(7),
                hover = if room.select then look.hover else nil, onClick = room.select,
                look.glyph{ name = room.symbol, w = 18, h = 18,
                    color = if room.joined then "accent" else "secondaryForeground" },
                ui.column{ gap = 1, center = false, grow = 1,
                    look.text{ text = room.name, size = 13, maxWidth = inner - 100,
                        weight = if room.joined then "semibold" else nil },
                    look.text{ text = room.title, size = 11, color = "secondaryForeground",
                        maxWidth = inner - 100 } } },
            if room.button then look.button(room.button, room.command) else ui.box{ w = 28, h = 1 } }
    end
    return look.group(rows)
end

function sonos.level(ctx, width: number?, m)
    width = width or look.width
    local inner = width - 24
    local volume = m.volume
    local rows = { w = width,
        look.heading(m.room),
        ui.row{ w = inner, gap = 8,
            look.glyph{ name = "hifispeaker.fill", w = 18, h = 18 },
            ui.slider{ value = volume.level, w = inner - 112, h = 16,
                color = if volume.muted then "mutedForeground" else "accent", onChange = volume.set },
            look.text{ text = volume.percent, size = 12, w = 42, reserve = ctx.format.percent(1) },
            look.button(volume.symbol, volume.mute) } }
    for _, room in volume.rooms or {} do
        rows[#rows + 1] = ui.row{ w = inner, gap = 8,
            look.text{ text = room.name, size = 12, w = 96, maxWidth = 96, color = "secondaryForeground" },
            ui.slider{ value = room.level, w = inner - 190, h = 14,
                color = if room.muted or volume.muted then "mutedForeground" else "accent", onChange = room.set },
            look.text{ text = room.percent, size = 12, w = 42, reserve = ctx.format.percent(1) },
            look.button(room.symbol, room.mute) }
    end
    return look.group(rows)
end

return table.freeze(sonos)
