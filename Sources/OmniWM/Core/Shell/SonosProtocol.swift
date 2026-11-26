// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SonosEndpoint: Hashable, Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    init?(location: String) {
        guard let url = URL(string: location), let host = url.host, !host.isEmpty else { return nil }
        self.init(host: host, port: url.port ?? 1400)
    }
}

struct SonosMember: Equatable, Sendable {
    let id: String
    let room: String
    let endpoint: SonosEndpoint
}

struct SonosZone: Equatable, Sendable {
    let id: String
    let endpoint: SonosEndpoint
    let members: [SonosMember]

    var rooms: [String] {
        members.reduce(into: []) { rooms, member in
            if !rooms.contains(member.room) { rooms.append(member.room) }
        }
    }
}

struct SonosTrack: Equatable, Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var artwork: String?
    var duration: Double?
    var elapsed: Double?
}

enum SonosService: Sendable {
    case transport
    case rendering
    case groupRendering
    case topology

    var name: String {
        switch self {
        case .transport: "AVTransport"
        case .rendering: "RenderingControl"
        case .groupRendering: "GroupRenderingControl"
        case .topology: "ZoneGroupTopology"
        }
    }

    var path: String {
        switch self {
        case .transport: "/MediaRenderer/AVTransport/Control"
        case .rendering: "/MediaRenderer/RenderingControl/Control"
        case .groupRendering: "/MediaRenderer/GroupRenderingControl/Control"
        case .topology: "/ZoneGroupTopology/Control"
        }
    }

    var hasInstance: Bool {
        self != .topology
    }
}

struct SonosCall: Equatable, Sendable {
    let service: SonosService
    let action: String
    var arguments: [String] = []
    var values: [String] = []

    init(_ service: SonosService, _ action: String, _ pairs: KeyValuePairs<String, String> = [:]) {
        self.service = service
        self.action = action
        arguments = pairs.map(\.key)
        values = pairs.map(\.value)
    }

    var soapAction: String {
        "\"urn:schemas-upnp-org:service:\(service.name):1#\(action)\""
    }

    var body: Data {
        var fields = service.hasInstance ? "<InstanceID>0</InstanceID>" : ""
        for (name, value) in zip(arguments, values) {
            fields += "<\(name)>\(SonosXML.escaped(value))</\(name)>"
        }
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:\(service.name):1\">\(fields)</u:\(action)>"
            + "</s:Body></s:Envelope>"
        return Data(envelope.utf8)
    }

    func request(to endpoint: SonosEndpoint) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = service.path
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(soapAction, forHTTPHeaderField: "SOAPACTION")
        return request
    }
}

final class SonosXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [SonosXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func first(_ name: String) -> SonosXMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    func all(_ name: String, into found: inout [SonosXMLNode]) {
        for child in children {
            if child.name == name { found.append(child) }
            child.all(name, into: &found)
        }
    }
}

private final class SonosXMLBuilder: NSObject, XMLParserDelegate {
    let root = SonosXMLNode(name: "", attributes: [:])
    private var stack: [SonosXMLNode] = []

    func parser(
        _: XMLParser, didStartElement name: String, namespaceURI _: String?, qualifiedName _: String?,
        attributes: [String: String]
    ) {
        let node = SonosXMLNode(name: name, attributes: attributes)
        (stack.last ?? root).children.append(node)
        stack.append(node)
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        stack.removeLast()
    }
}

enum SonosXML {
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func tree(_ data: Data) -> SonosXMLNode? {
        let builder = SonosXMLBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? builder.root : nil
    }

    static func value(_ name: String, in response: Data) -> String? {
        tree(response)?.first(name)?.text
    }

    static func seconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
            total = total * 60 + number
        }
        return total
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    static func zones(topology response: Data) -> [SonosZone] {
        guard let state = value("ZoneGroupState", in: response), let tree = tree(Data(state.utf8)) else { return [] }
        var groups: [SonosXMLNode] = []
        tree.all("ZoneGroup", into: &groups)
        return groups.compactMap { group in
            guard let coordinator = group.attributes["Coordinator"] else { return nil }
            let members = group.children.compactMap { node -> SonosMember? in
                guard node.name == "ZoneGroupMember", node.attributes["Invisible"] != "1",
                      let id = node.attributes["UUID"], let room = node.attributes["ZoneName"], !room.isEmpty,
                      let endpoint = node.attributes["Location"].flatMap(SonosEndpoint.init(location:))
                else { return nil }
                return SonosMember(id: id, room: room, endpoint: endpoint)
            }
            guard let lead = members.first(where: { $0.id == coordinator }) else { return nil }
            let others = members.filter { $0.id != coordinator }.sorted { ($0.room, $0.id) < ($1.room, $1.id) }
            return SonosZone(id: coordinator, endpoint: lead.endpoint, members: [lead] + others)
        }
        .sorted { ($0.rooms.first ?? "", $0.id) < ($1.rooms.first ?? "", $1.id) }
    }

    static func track(position response: Data) -> SonosTrack {
        guard let tree = tree(response) else { return SonosTrack() }
        var track = SonosTrack()
        track.duration = seconds(tree.first("TrackDuration")?.text).flatMap { $0 > 0 ? $0 : nil }
        track.elapsed = seconds(tree.first("RelTime")?.text)
        guard let metadata = tree.first("TrackMetaData")?.text, metadata.hasPrefix("<"),
              let item = self.tree(Data(metadata.utf8))
        else { return track }
        let text = { (name: String) in
            (item.first(name)?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        track.title = text("dc:title")
        track.artist = text("dc:creator")
        track.album = text("upnp:album")
        let stream = text("r:streamContent")
        if track.artist.isEmpty, !stream.isEmpty {
            track.title = stream
        }
        let artwork = text("upnp:albumArtURI")
        track.artwork = artwork.isEmpty ? nil : artwork
        return track
    }
}
