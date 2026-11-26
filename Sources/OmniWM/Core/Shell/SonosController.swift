// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CryptoKit
import ImageIO
import Network

enum ShellSonosCommand: Equatable, Sendable {
    case play(String)
    case pause(String)
    case toggle(String)
    case next(String)
    case previous(String)
    case mute(String)
    case seek(String, seconds: Double)
    case volume(String, percent: Int)
    case roomVolume(String, percent: Int)
    case roomMute(String)
    case join(String, group: String)
    case leave(String)
    case open

    init?(words: [String]) {
        switch words.count {
        case 1 where words[0] == "open":
            self = .open
        case 2:
            switch words[0] {
            case "play": self = .play(words[1])
            case "pause": self = .pause(words[1])
            case "toggle": self = .toggle(words[1])
            case "next": self = .next(words[1])
            case "previous": self = .previous(words[1])
            case "mute": self = .mute(words[1])
            case "leave": self = .leave(words[1])
            case "room-mute": self = .roomMute(words[1])
            default: return nil
            }
        case 3 where words[0] == "seek":
            guard let seconds = Double(words[2]), seconds.isFinite, seconds >= 0 else { return nil }
            self = .seek(words[1], seconds: seconds)
        case 3 where words[0] == "volume" || words[0] == "room-volume":
            guard let percent = Double(words[2]), percent.isFinite, (0 ... 100).contains(percent) else { return nil }
            self = words[0] == "volume" ? .volume(words[1], percent: Int(percent.rounded()))
                : .roomVolume(words[1], percent: Int(percent.rounded()))
        case 3 where words[0] == "join" && words[1] != words[2]:
            self = .join(words[1], group: words[2])
        default:
            return nil
        }
    }

    var zone: String? {
        switch self {
        case let .play(zone),
             let .pause(zone),
             let .toggle(zone),
             let .next(zone),
             let .previous(zone),
             let .mute(zone),
             let .seek(zone, _),
             let .volume(zone, _): zone
        case .roomVolume,
             .roomMute,
             .join,
             .leave,
             .open: nil
        }
    }

    var member: String? {
        switch self {
        case let .roomVolume(member, _),
             let .roomMute(member),
             let .join(member, _),
             let .leave(member): member
        default: nil
        }
    }

    var prelude: SonosCall? {
        if case .volume = self { SonosCall(.groupRendering, "SnapshotGroupVolume") } else { nil }
    }

    var regroups: Bool {
        switch self {
        case .join,
             .leave: true
        default: false
        }
    }

    func call(playing: Bool, muted: Bool) -> SonosCall? {
        switch self {
        case .play: SonosCall(.transport, "Play", ["Speed": "1"])
        case .pause: SonosCall(.transport, "Pause")
        case .toggle: playing ? SonosCall(.transport, "Pause") : SonosCall(.transport, "Play", ["Speed": "1"])
        case .next: SonosCall(.transport, "Next")
        case .previous: SonosCall(.transport, "Previous")
        case .mute: SonosCall(.groupRendering, "SetGroupMute", ["DesiredMute": muted ? "0" : "1"])
        case let .seek(_, seconds):
            SonosCall(.transport, "Seek", ["Unit": "REL_TIME", "Target": SonosXML.clock(seconds)])
        case let .volume(_, percent):
            SonosCall(.groupRendering, "SetGroupVolume", ["DesiredVolume": String(percent)])
        case let .roomVolume(_, percent):
            SonosCall(.rendering, "SetVolume", ["Channel": "Master", "DesiredVolume": String(percent)])
        case .roomMute:
            SonosCall(.rendering, "SetMute", ["Channel": "Master", "DesiredMute": muted ? "0" : "1"])
        case let .join(_, group):
            SonosCall(.transport, "SetAVTransportURI", ["CurrentURI": "x-rincon:" + group, "CurrentURIMetaData": ""])
        case .leave: SonosCall(.transport, "BecomeCoordinatorOfStandaloneGroup")
        case .open: nil
        }
    }
}

struct ShellSonos: Equatable, Sendable, ShellValueWritable {
    struct Group: Equatable, Sendable {
        struct Member: Equatable, Sendable {
            var id = ""
            var room = ""
            var volume: Double?
            var muted: Bool?
        }

        var id = ""
        var rooms: [String] = []
        var members: [Member] = []
        var title = ""
        var artist = ""
        var album = ""
        var playing = false
        var duration: Double?
        var elapsed: Double?
        var sampledAt = 0.0
        var artwork: String?
        var volume: Double?
        var muted: Bool?

        func keepingClock(of previous: Group?) -> Group {
            guard let previous, previous.playing == playing, previous.title == title, previous.artist == artist,
                  previous.duration == duration, let before = previous.elapsed, let now = elapsed
            else { return self }
            let expected = before + (playing ? sampledAt - previous.sampledAt : 0)
            guard abs(expected - now) < 1.5 else { return self }
            var steady = self
            steady.elapsed = before
            steady.sampledAt = previous.sampledAt
            return steady
        }
    }

    var groups: [Group] = []

    func write(into writer: inout ShellValueWriter) {
        writer.map(1)
        writer.key("groups")
        writer.array(groups.count)
        for group in groups {
            writer.map(14)
            writer.key("id")
            writer.string(group.id)
            writer.key("members")
            writer.array(group.members.count)
            for member in group.members {
                writer.map(4)
                writer.key("id")
                writer.string(member.id)
                writer.key("room")
                writer.string(member.room)
                writer.key("volume")
                member.volume.map { writer.number($0) } ?? writer.null()
                writer.key("muted")
                member.muted.map { writer.bool($0) } ?? writer.null()
            }
            writer.key("room")
            writer.string(group.rooms.joined(separator: " + "))
            writer.key("rooms")
            writer.array(group.rooms.count)
            for room in group.rooms {
                writer.string(room)
            }
            writer.key("title")
            writer.string(group.title)
            writer.key("artist")
            writer.string(group.artist)
            writer.key("album")
            writer.string(group.album)
            writer.key("playing")
            writer.bool(group.playing)
            writer.key("duration")
            group.duration.map { writer.number($0) } ?? writer.null()
            writer.key("elapsed")
            group.elapsed.map { writer.number($0) } ?? writer.null()
            writer.key("sampledAt")
            writer.number(group.sampledAt)
            writer.key("artwork")
            group.artwork.map { writer.string($0) } ?? writer.null()
            writer.key("volume")
            group.volume.map { writer.number($0) } ?? writer.null()
            writer.key("muted")
            group.muted.map { writer.bool($0) } ?? writer.null()
        }
    }
}

struct SonosTransport: Sendable {
    var send: @Sendable (URLRequest) async throws -> Data

    static let live: SonosTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return SonosTransport { request in
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }()
}

struct SonosSample: Equatable, Sendable {
    struct Room: Equatable, Sendable {
        var volume: Double?
        var muted: Bool?
    }

    var track = SonosTrack()
    var playing = false
    var volume: Double?
    var muted: Bool?
    var rooms: [String: Room] = [:]
    var sampledAt = 0.0

    static func read(_ zone: SonosZone, transport: SonosTransport) async -> SonosSample? {
        async let state = send(SonosCall(.transport, "GetTransportInfo"), to: zone, transport)
        async let position = send(SonosCall(.transport, "GetPositionInfo"), to: zone, transport)
        async let volume = send(SonosCall(.groupRendering, "GetGroupVolume"), to: zone, transport)
        async let mute = send(SonosCall(.groupRendering, "GetGroupMute"), to: zone, transport)
        async let rooms = rooms(of: zone, transport)
        let answers = await (state, position, volume, mute)
        guard let state = answers.0, let position = answers.1 else { return nil }
        var sample = SonosSample()
        sample.sampledAt = Date().timeIntervalSince1970
        sample.track = SonosXML.track(position: position)
        let transportState = SonosXML.value("CurrentTransportState", in: state) ?? ""
        sample.playing = transportState == "PLAYING" || transportState == "TRANSITIONING"
        sample.volume = answers.2.flatMap { SonosXML.value("CurrentVolume", in: $0) }.flatMap(Double.init)
        sample.muted = answers.3.flatMap { SonosXML.value("CurrentMute", in: $0) }.map { $0 == "1" }
        sample.rooms = await rooms
        return sample
    }

    private static func rooms(of zone: SonosZone, _ transport: SonosTransport) async -> [String: Room] {
        guard zone.members.count > 1 else { return [:] }
        return await withTaskGroup(of: (String, Room).self) { tasks in
            for member in zone.members {
                tasks.addTask {
                    async let volume = send(
                        SonosCall(.rendering, "GetVolume", ["Channel": "Master"]), to: member.endpoint, transport
                    )
                    async let mute = send(
                        SonosCall(.rendering, "GetMute", ["Channel": "Master"]), to: member.endpoint, transport
                    )
                    let answers = await (volume, mute)
                    return (member.id, Room(
                        volume: answers.0.flatMap { SonosXML.value("CurrentVolume", in: $0) }.flatMap(Double.init),
                        muted: answers.1.flatMap { SonosXML.value("CurrentMute", in: $0) }.map { $0 == "1" }
                    ))
                }
            }
            var rooms: [String: Room] = [:]
            for await (id, room) in tasks {
                rooms[id] = room
            }
            return rooms
        }
    }

    private static func send(_ call: SonosCall, to zone: SonosZone, _ transport: SonosTransport) async -> Data? {
        await send(call, to: zone.endpoint, transport)
    }

    private static func send(_ call: SonosCall, to endpoint: SonosEndpoint, _ transport: SonosTransport) async -> Data? {
        guard let request = call.request(to: endpoint) else { return nil }
        return try? await transport.send(request)
    }
}

@MainActor
final class SonosController {
    static let bundleIdentifiers: Set = ["com.sonos.macController2", "com.sonos.macController"]
    static let artworkPrefix = "sonos/"
    private static let zoneLifetime = Duration.seconds(30)

    private let transport: SonosTransport
    private let appRunning: @MainActor () -> Bool
    private let browses: Bool
    private var listening = false
    private var observers: [NSObjectProtocol] = []
    private var browser: NWBrowser?
    private var discovered: Set<SonosEndpoint> = []
    private var zones: [SonosZone] = []
    private var zonesLoaded: ContinuousClock.Instant?
    private var loop: Task<Void, Never>?
    private var epoch = 0
    private var refreshing: Task<Bool, Never>?
    private var artworks: [String: (id: String, image: CGImage?)] = [:]
    private(set) var sonos: ShellSonos?
    var onChange: (@MainActor (ShellSonos?) -> Void)?

    init(
        transport: SonosTransport = .live,
        browses: Bool = true,
        appRunning: @escaping @MainActor () -> Bool = SonosController.sonosAppIsRunning
    ) {
        self.transport = transport
        self.browses = browses
        self.appRunning = appRunning
    }

    static func sonosAppIsRunning() -> Bool {
        sonosApp() != nil
    }

    private static func sonosApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && bundleIdentifiers.contains($0.bundleIdentifier ?? "")
        }
    }

    func bitmap(_ id: String) -> CGImage? {
        guard id.hasPrefix(Self.artworkPrefix) else { return nil }
        return artworks.values.first { Self.artworkPrefix + $0.id == id }?.image
    }

    func offer(_ endpoints: Set<SonosEndpoint>) {
        let hadNone = discovered.isEmpty && zones.isEmpty
        discovered = endpoints
        if hadNone, !endpoints.isEmpty, loop != nil {
            Task { [weak self] in await self?.refresh() }
        }
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        let center = NSWorkspace.shared.notificationCenter
        if listening {
            for name in [
                NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification
            ] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
            }
        } else {
            observers.forEach(center.removeObserver)
            observers = []
        }
        update()
    }

    func update() {
        guard listening, appRunning() else {
            epoch += 1
            loop?.cancel()
            loop = nil
            browser?.cancel()
            browser = nil
            discovered = []
            zones = []
            zonesLoaded = nil
            artworks = [:]
            publish(nil)
            return
        }
        guard loop == nil else { return }
        browse()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let playing = await self?.refresh() else { return }
                do {
                    try await Task.sleep(for: .seconds(playing ? 2 : 5))
                } catch {
                    return
                }
            }
        }
    }

    func perform(_ command: ShellSonosCommand) {
        if command == .open {
            Self.sonosApp()?.activate()
            return
        }
        let regroups = command.regroups
        let endpoint: SonosEndpoint? = if let member = command.member {
            zones.lazy.flatMap(\.members).first { $0.id == member }?.endpoint
        } else {
            zones.first { $0.id == command.zone }?.endpoint
        }
        if case let .join(_, group) = command, !zones.contains(where: { $0.id == group }) { return }
        let group = sonos?.groups.first { $0.id == command.zone }
        let muted = if let member = command.member {
            sonos?.groups.lazy.flatMap(\.members).first { $0.id == member }?.muted == true
        } else {
            group?.muted == true
        }
        guard let endpoint, let call = command.call(playing: group?.playing == true, muted: muted),
              let request = call.request(to: endpoint)
        else { return }
        let prelude = command.prelude?.request(to: endpoint)
        Task { [weak self, transport] in
            do {
                if let prelude {
                    _ = try await transport.send(prelude)
                }
                _ = try await transport.send(request)
            } catch {
                Log.shell.error("The Sonos command \(call.action) did not reach \(endpoint.host): \(error)")
            }
            guard regroups else {
                await self?.refresh()
                return
            }
            for delay in [Duration.zero, .seconds(1.5)] {
                try? await Task.sleep(for: delay)
                self?.zonesLoaded = nil
                await self?.refresh()
            }
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        if let refreshing {
            _ = await refreshing.value
        }
        if let refreshing {
            return await refreshing.value
        }
        let epoch = epoch
        let task = Task { await self.read(epoch: epoch) }
        refreshing = task
        let playing = await task.value
        refreshing = nil
        return playing
    }

    private func read(epoch: Int) async -> Bool {
        if zones.isEmpty || zonesLoaded.map({ $0.duration(to: .now) > Self.zoneLifetime }) ?? true {
            let loaded = await loadZones()
            guard epoch == self.epoch else { return false }
            zones = loaded
            zonesLoaded = loaded.isEmpty ? nil : .now
        }
        let zones = zones
        let transport = transport
        let samples = await withTaskGroup(of: (Int, SonosSample?).self) { tasks in
            for (index, zone) in zones.enumerated() {
                tasks.addTask { await (index, SonosSample.read(zone, transport: transport)) }
            }
            var samples = [SonosSample?](repeating: nil, count: zones.count)
            for await (index, sample) in tasks {
                samples[index] = sample
            }
            return samples
        }
        guard epoch == self.epoch else { return false }
        if !zones.isEmpty, samples.allSatisfy({ $0 == nil }) {
            self.zones = []
            zonesLoaded = nil
        }
        var groups: [ShellSonos.Group] = []
        var shownArtworks: Set<String> = []
        for (zone, sample) in zip(zones, samples) {
            guard let sample else { continue }
            var group = ShellSonos.Group(
                id: zone.id, rooms: zone.rooms,
                members: zone.members.map {
                    ShellSonos.Group.Member(
                        id: $0.id, room: $0.room, volume: sample.rooms[$0.id]?.volume,
                        muted: sample.rooms[$0.id]?.muted
                    )
                },
                title: sample.track.title, artist: sample.track.artist,
                album: sample.track.album, playing: sample.playing, duration: sample.track.duration,
                elapsed: sample.track.elapsed, sampledAt: sample.sampledAt, volume: sample.volume,
                muted: sample.muted
            )
            if let address = Self.artworkAddress(sample.track.artwork, on: zone.endpoint) {
                shownArtworks.insert(address)
                group.artwork = artwork(at: address)
            }
            groups.append(group.keepingClock(of: sonos?.groups.first { $0.id == zone.id }))
        }
        artworks = artworks.filter { shownArtworks.contains($0.key) }
        publish(ShellSonos(groups: groups))
        return groups.contains(where: \.playing)
    }

    static func artworkAddress(_ artwork: String?, on endpoint: SonosEndpoint) -> String? {
        guard let artwork, !artwork.isEmpty else { return nil }
        if artwork.hasPrefix("http://") || artwork.hasPrefix("https://") { return artwork }
        return "http://\(endpoint.host):\(endpoint.port)" + (artwork.hasPrefix("/") ? artwork : "/" + artwork)
    }

    private func artwork(at address: String) -> String? {
        if let known = artworks[address] {
            return known.image == nil ? nil : Self.artworkPrefix + known.id
        }
        let digest = SHA256.hash(data: Data(address.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        artworks[address] = (digest, nil)
        guard let url = URL(string: address) else { return nil }
        Task { [weak self, transport] in
            guard let data = try? await transport.send(URLRequest(url: url)), let self,
                  artworks[address] != nil, let image = Self.image(data)
            else { return }
            artworks[address] = (digest, image)
            await refresh()
        }
        return nil
    }

    private static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func loadZones() async -> [SonosZone] {
        var candidates = zones.map(\.endpoint)
        for endpoint in discovered.sorted(by: { ($0.host, $0.port) < ($1.host, $1.port) })
            where !candidates.contains(endpoint)
        {
            candidates.append(endpoint)
        }
        for endpoint in candidates {
            guard let request = SonosCall(.topology, "GetZoneGroupState").request(to: endpoint),
                  let answer = try? await transport.send(request)
            else { continue }
            let found = SonosXML.zones(topology: answer)
            if !found.isEmpty { return found }
        }
        return []
    }

    private func browse() {
        guard browses, browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = Set(results.compactMap { result -> SonosEndpoint? in
                guard case let .bonjour(record) = result.metadata, let location = record["location"] else {
                    return nil
                }
                return SonosEndpoint(location: location)
            })
            MainActor.assumeIsolated { self?.offer(endpoints) }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Log.shell.error("Looking for Sonos speakers on the local network failed: \(error)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func publish(_ sonos: ShellSonos?) {
        guard sonos != self.sonos else { return }
        self.sonos = sonos
        onChange?(sonos)
    }
}
