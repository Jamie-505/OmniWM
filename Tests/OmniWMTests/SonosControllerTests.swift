// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import Synchronization
import XCTest

@MainActor
final class SonosControllerTests: XCTestCase {
    private nonisolated static let office = "RINCON_OFFICE01400"
    private nonisolated static let living = "RINCON_LIVING01400"

    private nonisolated static func envelope(_ action: String, _ fields: String) -> Data {
        Data("""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:X:1">\(fields)</u:\(action)Response>\
        </s:Body></s:Envelope>
        """.utf8)
    }

    private nonisolated static let topology = envelope("GetZoneGroupState", "<ZoneGroupState>" + SonosXML.escaped("""
    <ZoneGroupState><ZoneGroups>\
    <ZoneGroup Coordinator="\(office)" ID="\(office):1">\
    <ZoneGroupMember UUID="\(office)" Location="http://10.0.0.2:1400/xml/device_description.xml" \
    ZoneName="Office"/></ZoneGroup>\
    <ZoneGroup Coordinator="\(living)" ID="\(living):2">\
    <ZoneGroupMember UUID="RINCON_KITCHEN01400" Location="http://10.0.0.4:1400/xml/device_description.xml" \
    ZoneName="Kitchen"/>\
    <ZoneGroupMember UUID="\(living)" Location="http://10.0.0.3:1400/xml/device_description.xml" \
    ZoneName="Living Room">\
    <Satellite UUID="RINCON_SUB01400" Location="http://10.0.0.5:1400/xml/device_description.xml" \
    ZoneName="Sub" Invisible="1"/></ZoneGroupMember>\
    <ZoneGroupMember UUID="RINCON_HIDDEN01400" Location="http://10.0.0.6:1400/xml/device_description.xml" \
    ZoneName="Living Room" Invisible="1"/>\
    </ZoneGroup></ZoneGroups></ZoneGroupState>
    """) + "</ZoneGroupState>")

    private nonisolated static func position(title: String, artist: String, elapsed: String, artwork: String = "") -> Data {
        let metadata = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" \
        xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="-1">\
        <r:streamContent></r:streamContent><upnp:albumArtURI>\(SonosXML.escaped(artwork))</upnp:albumArtURI>\
        <dc:title>\(title)</dc:title><dc:creator>\(artist)</dc:creator><upnp:album>Album</upnp:album>\
        </item></DIDL-Lite>
        """
        return envelope(
            "GetPositionInfo",
            "<TrackDuration>0:03:20</TrackDuration><TrackMetaData>\(SonosXML.escaped(metadata))</TrackMetaData>"
                + "<RelTime>\(elapsed)</RelTime>"
        )
    }

    private final class App {
        var running = true
    }

    private final class Speakers: Sendable {
        let playing = Mutex<Set<String>>(["10.0.0.2"])
        let sent = Mutex<[String]>([])

        var transport: SonosTransport {
            SonosTransport { [self] request in
                let host = request.url?.host ?? ""
                let action = (request.value(forHTTPHeaderField: "SOAPACTION") ?? "")
                    .split(separator: "#").last.map { String($0.dropLast()) } ?? ""
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                switch action {
                case "GetZoneGroupState":
                    return SonosControllerTests.topology
                case "GetTransportInfo":
                    let state = playing.withLock { $0.contains(host) } ? "PLAYING" : "PAUSED_PLAYBACK"
                    return SonosControllerTests.envelope(
                        action, "<CurrentTransportState>\(state)</CurrentTransportState>"
                    )
                case "GetPositionInfo":
                    return host == "10.0.0.2"
                        ? SonosControllerTests.position(title: "Song", artist: "Artist", elapsed: "0:00:50")
                        : SonosControllerTests.position(title: "Other", artist: "", elapsed: "0:01:00")
                case "GetGroupVolume":
                    return SonosControllerTests.envelope(action, "<CurrentVolume>40</CurrentVolume>")
                case "GetVolume":
                    return SonosControllerTests.envelope(action, "<CurrentVolume>25</CurrentVolume>")
                case "GetMute":
                    return SonosControllerTests.envelope(action, "<CurrentMute>1</CurrentMute>")
                case "GetGroupMute":
                    return SonosControllerTests.envelope(action, "<CurrentMute>0</CurrentMute>")
                default:
                    sent.withLock { $0.append("\(host) \(action) \(body.contains("<Speed>1</Speed>"))") }
                    if action == "Pause" { playing.withLock { _ = $0.remove(host) } }
                    if action == "Play" { playing.withLock { _ = $0.insert(host) } }
                    return SonosControllerTests.envelope(action, "")
                }
            }
        }
    }

    func testSonosCommandsParseWithTheirGroup() {
        XCTAssertEqual(ShellAction("sonos toggle RINCON_1"), .sonos(.toggle("RINCON_1")))
        XCTAssertEqual(ShellAction("sonos seek RINCON_1 12.5"), .sonos(.seek("RINCON_1", seconds: 12.5)))
        XCTAssertEqual(ShellAction("sonos volume RINCON_1 40"), .sonos(.volume("RINCON_1", percent: 40)))
        XCTAssertEqual(ShellAction("sonos open"), .sonos(.open))
        XCTAssertNil(ShellAction("sonos toggle"))
        XCTAssertNil(ShellAction("sonos volume RINCON_1 101"))
        XCTAssertNil(ShellAction("sonos seek RINCON_1 -1"))
        XCTAssertEqual(ShellAction("sonos join RINCON_2 RINCON_1"), .sonos(.join("RINCON_2", group: "RINCON_1")))
        XCTAssertEqual(ShellAction("sonos leave RINCON_2"), .sonos(.leave("RINCON_2")))
        XCTAssertEqual(ShellAction("sonos room-volume RINCON_2 30"), .sonos(.roomVolume("RINCON_2", percent: 30)))
        XCTAssertEqual(ShellAction("sonos room-mute RINCON_2"), .sonos(.roomMute("RINCON_2")))
        XCTAssertEqual(
            ShellSonosCommand.roomMute("RINCON_2").call(playing: false, muted: true),
            SonosCall(.rendering, "SetMute", ["Channel": "Master", "DesiredMute": "0"])
        )
        XCTAssertEqual(
            ShellSonosCommand.volume("RINCON_1", percent: 30).prelude,
            SonosCall(.groupRendering, "SnapshotGroupVolume")
        )
        XCTAssertNil(ShellSonosCommand.roomVolume("RINCON_2", percent: 30).prelude)
        XCTAssertEqual(
            ShellSonosCommand.roomVolume("RINCON_2", percent: 30).call(playing: false, muted: false),
            SonosCall(.rendering, "SetVolume", ["Channel": "Master", "DesiredVolume": "30"])
        )
        XCTAssertNil(ShellAction("sonos join RINCON_1 RINCON_1"))
        XCTAssertEqual(
            ShellSonosCommand.join("RINCON_2", group: "RINCON_1").call(playing: false, muted: false),
            SonosCall(.transport, "SetAVTransportURI", ["CurrentURI": "x-rincon:RINCON_1", "CurrentURIMetaData": ""])
        )
        XCTAssertEqual(
            ShellSonosCommand.seek("RINCON_1", seconds: 75).call(playing: true, muted: false),
            SonosCall(.transport, "Seek", ["Unit": "REL_TIME", "Target": "0:01:15"])
        )
        XCTAssertEqual(
            ShellSonosCommand.mute("RINCON_1").call(playing: true, muted: true),
            SonosCall(.groupRendering, "SetGroupMute", ["DesiredMute": "0"])
        )
    }

    func testTopologyListsVisibleRoomsUnderTheirCoordinator() {
        XCTAssertEqual(SonosXML.zones(topology: Self.topology), [
            SonosZone(
                id: Self.living, endpoint: SonosEndpoint(host: "10.0.0.3", port: 1400),
                members: [
                    SonosMember(
                        id: Self.living, room: "Living Room", endpoint: SonosEndpoint(host: "10.0.0.3", port: 1400)
                    ),
                    SonosMember(
                        id: "RINCON_KITCHEN01400", room: "Kitchen",
                        endpoint: SonosEndpoint(host: "10.0.0.4", port: 1400)
                    )
                ]
            ),
            SonosZone(
                id: Self.office, endpoint: SonosEndpoint(host: "10.0.0.2", port: 1400),
                members: [
                    SonosMember(id: Self.office, room: "Office", endpoint: SonosEndpoint(host: "10.0.0.2", port: 1400))
                ]
            )
        ])
        XCTAssertEqual(SonosXML.zones(topology: Self.topology).first?.rooms, ["Living Room", "Kitchen"])
    }

    func testPositionReadsTheTrackAndItsTimes() {
        let track = SonosXML.track(position: Self.position(
            title: "Song &amp; Dance", artist: "Artist", elapsed: "0:00:50", artwork: "/getaa?s=1&u=x"
        ))
        XCTAssertEqual(track.title, "Song & Dance")
        XCTAssertEqual(track.artist, "Artist")
        XCTAssertEqual(track.album, "Album")
        XCTAssertEqual(track.artwork, "/getaa?s=1&u=x")
        XCTAssertEqual(track.duration, 200)
        XCTAssertEqual(track.elapsed, 50)
        XCTAssertEqual(
            SonosController.artworkAddress(track.artwork, on: SonosEndpoint(host: "10.0.0.2", port: 1400)),
            "http://10.0.0.2:1400/getaa?s=1&u=x"
        )
        let idle = SonosXML.track(position: Self.envelope(
            "GetPositionInfo",
            "<TrackDuration>NOT_IMPLEMENTED</TrackDuration><TrackMetaData>NOT_IMPLEMENTED</TrackMetaData>"
        ))
        XCTAssertEqual(idle, SonosTrack())
    }

    func testTheControllerPublishesGroupsOnlyWhileTheSonosAppRuns() async {
        let speakers = Speakers()
        let app = App()
        let controller = SonosController(transport: speakers.transport, browses: false) { app.running }
        controller.offer([SonosEndpoint(host: "10.0.0.2", port: 1400)])
        controller.setListening(true)
        let playing = await controller.refresh()
        XCTAssertTrue(playing)
        let groups = controller.sonos?.groups ?? []
        XCTAssertEqual(groups.map(\.id), [Self.living, Self.office])
        XCTAssertEqual(groups.map(\.playing), [false, true])
        XCTAssertEqual(groups.last?.title, "Song")
        XCTAssertEqual(groups.last?.elapsed, 50)
        XCTAssertEqual(groups.last?.volume, 40)
        XCTAssertEqual(groups.last?.muted, false)

        app.running = false
        controller.update()
        XCTAssertNil(controller.sonos)
        controller.setListening(false)
    }

    func testToggleSendsPauseToThePlayingGroup() async {
        let speakers = Speakers()
        let controller = SonosController(transport: speakers.transport, browses: false) { true }
        controller.offer([SonosEndpoint(host: "10.0.0.2", port: 1400)])
        controller.setListening(true)
        await controller.refresh()
        var changes = 0
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        controller.onChange = { sonos in
            changes += 1
            if sonos?.groups.last?.playing == false { continuation.yield() }
        }
        controller.perform(.toggle(Self.office))
        for await _ in stream {
            break
        }
        XCTAssertEqual(speakers.sent.withLock { $0 }, ["10.0.0.2 Pause false"])
        XCTAssertEqual(controller.sonos?.groups.last?.playing, false)
        XCTAssertGreaterThan(changes, 0)
        controller.setListening(false)
    }

    func testJoinAndLeaveGoToTheRoomThatMoves() async throws {
        let speakers = Speakers()
        let controller = SonosController(transport: speakers.transport, browses: false) { true }
        controller.offer([SonosEndpoint(host: "10.0.0.2", port: 1400)])
        controller.setListening(true)
        await controller.refresh()
        XCTAssertEqual(controller.sonos?.groups.first?.members.map(\.room), ["Living Room", "Kitchen"])
        XCTAssertEqual(controller.sonos?.groups.first?.members.map(\.volume), [25, 25])
        XCTAssertEqual(controller.sonos?.groups.first?.members.map(\.muted), [true, true])
        XCTAssertEqual(controller.sonos?.groups.last?.members.map(\.volume), [nil])
        controller.perform(.roomVolume("RINCON_KITCHEN01400", percent: 30))
        controller.perform(.leave("RINCON_KITCHEN01400"))
        controller.perform(.join(Self.office, group: Self.living))
        controller.perform(.join(Self.office, group: "RINCON_UNKNOWN"))
        for _ in 0 ..< 400 where speakers.sent.withLock({ $0.count }) < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(Set(speakers.sent.withLock { $0 }), [
            "10.0.0.4 SetVolume false", "10.0.0.4 BecomeCoordinatorOfStandaloneGroup false",
            "10.0.0.2 SetAVTransportURI false"
        ])
        controller.setListening(false)
    }

    func testGroupVolumeSnapshotsTheRoomBalanceFirst() async throws {
        let speakers = Speakers()
        let controller = SonosController(transport: speakers.transport, browses: false) { true }
        controller.offer([SonosEndpoint(host: "10.0.0.2", port: 1400)])
        controller.setListening(true)
        await controller.refresh()
        controller.perform(.volume(Self.living, percent: 30))
        for _ in 0 ..< 400 where speakers.sent.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            speakers.sent.withLock { $0 }, ["10.0.0.3 SnapshotGroupVolume false", "10.0.0.3 SetGroupVolume false"]
        )
        controller.perform(.roomMute("RINCON_KITCHEN01400"))
        for _ in 0 ..< 400 where speakers.sent.withLock({ $0.count }) < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(speakers.sent.withLock { $0.last }, "10.0.0.4 SetMute false")
        controller.setListening(false)
    }

    func testASteadyTrackKeepsItsFirstClockSample() {
        var first = ShellSonos.Group(id: "a", title: "Song", playing: true, duration: 200, elapsed: 50, sampledAt: 100)
        var next = first
        next.elapsed = 52
        next.sampledAt = 102
        XCTAssertEqual(next.keepingClock(of: first), first)
        next.elapsed = 120
        XCTAssertEqual(next.keepingClock(of: first), next)
        first.playing = false
        XCTAssertEqual(next.keepingClock(of: first), next)
    }

    func testTheSonosWidgetShowsThePlayingGroupFromTheChosenRooms() throws {
        let widget = try ShellRenderedWidget("sonos")
        var sonos = ShellSonos()
        sonos.groups = [
            ShellSonos.Group(
                id: Self.living, rooms: ["Living Room"], members: [.init(id: Self.living, room: "Living Room")],
                title: "Other", playing: true, sampledAt: 1_000_000
            ),
            ShellSonos.Group(
                id: Self.office, rooms: ["Office"], members: [.init(id: Self.office, room: "Office")],
                title: "Song", artist: "Artist", playing: true, duration: 200,
                elapsed: 20, sampledAt: 1_000_000, volume: 40, muted: false
            )
        ]
        widget.set("seconds") { $0.number(1_000_010) }
        widget.set("sonos") { sonos.write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Other"))

        widget.set("settings") { writer in
            writer.map(1)
            writer.key("rooms")
            writer.array(1)
            writer.string("office")
        }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Song"))
        let nodes = widget.renderPopout()
        let actions = Set(nodes.map { widget.text.string($0.content.action) })
        XCTAssertTrue(actions.isSuperset(of: [
            "sonos previous \(Self.office)", "sonos toggle \(Self.office)", "sonos next \(Self.office)",
            "sonos mute \(Self.office)", "sonos open"
        ]))
        let popout = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(popout.contains("0:30"))
        XCTAssertTrue(popout.contains("Office"))
        let sliders = nodes.filter { $0.kind == .slider }.map(\.content.action)
        XCTAssertEqual(sliders.count, 2)
        var event = ShellEvent(button: .left)
        event.value = 0.5
        event.phase = .ended
        XCTAssertEqual(
            widget.invoke(sliders[0], view: OMNI_VIEW_POPOUT, event: event), ["sonos seek \(Self.office) 100"]
        )
        XCTAssertEqual(
            widget.invoke(sliders[1], view: OMNI_VIEW_POPOUT, event: event), ["sonos volume \(Self.office) 50"]
        )

        widget.set("sonos") { $0.null() }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.surface.size, .zero)
    }

    func testThePopoutListsRoomsToChooseJoinAndSplit() throws {
        let widget = try ShellRenderedWidget("sonos")
        let kitchen = "RINCON_KITCHEN01400"
        var sonos = ShellSonos()
        sonos.groups = [
            ShellSonos.Group(
                id: Self.living, rooms: ["Living Room", "Kitchen"],
                members: [
                    .init(id: Self.living, room: "Living Room", volume: 20, muted: false),
                    .init(id: kitchen, room: "Kitchen", volume: 40, muted: true)
                ],
                title: "Other", playing: true, sampledAt: 1, volume: 30, muted: false
            ),
            ShellSonos.Group(
                id: Self.office, rooms: ["Office"], members: [.init(id: Self.office, room: "Office")],
                title: "Song", playing: true, sampledAt: 1
            ),
            ShellSonos.Group(id: "RINCON_IDLE", rooms: ["Move"], members: [.init(id: "RINCON_IDLE", room: "Move")])
        ]
        widget.set("seconds") { $0.number(10) }
        widget.set("sonos") { sonos.write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Other"))
        let nodes = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Rooms"))
        let actions = nodes.map { widget.text.string($0.content.action) }
        XCTAssertEqual(Set(actions.filter { $0.hasPrefix("sonos toggle") }), ["sonos toggle \(Self.living)"])
        XCTAssertEqual(
            Set(actions.filter { $0.hasPrefix("sonos room-mute") }),
            ["sonos room-mute \(Self.living)", "sonos room-mute \(kitchen)"]
        )
        XCTAssertEqual(Set(actions.filter { $0.hasPrefix("sonos leave") || $0.hasPrefix("sonos join") }), [
            "sonos leave \(Self.living)", "sonos leave \(kitchen)", "sonos join \(Self.office) \(Self.living)",
            "sonos join RINCON_IDLE \(Self.living)"
        ])
        let sliders = nodes.filter { $0.kind == .slider }.map(\.content.action)
        XCTAssertEqual(sliders.count, 3)
        var event = ShellEvent(button: .left)
        event.value = 0.5
        event.phase = .ended
        XCTAssertEqual(
            sliders.map { widget.invoke($0, view: OMNI_VIEW_POPOUT, event: event) },
            [["sonos volume \(Self.living) 50"], ["sonos room-volume \(Self.living) 50"],
             ["sonos room-volume \(kitchen) 50"]]
        )
        let rows = nodes.filter { $0.kind != .slider && $0.content.action != 0 }
            .filter { widget.text.string($0.content.action).isEmpty }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(widget.invoke(rows[0].content.action, view: OMNI_VIEW_POPOUT), [])
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Song"))
        let chosen = Set(widget.renderPopout().map { widget.text.string($0.content.action) })
        XCTAssertTrue(chosen.isSuperset(of: [
            "sonos toggle \(Self.office)", "sonos join \(kitchen) \(Self.office)",
            "sonos join RINCON_IDLE \(Self.office)"
        ]))
        XCTAssertFalse(chosen.contains("sonos leave \(Self.office)"))

        sonos.groups[1].title = ""
        widget.set("sonos") { sonos.write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Other"))
    }
}
