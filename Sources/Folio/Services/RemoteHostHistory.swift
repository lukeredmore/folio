import Foundation

/// SSH connection settings for one host, remembered so a new mount can reuse them.
public struct RemoteHostProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?
    public var identityFile: String?

    public init(user: String? = nil, host: String, port: Int? = nil, identityFile: String? = nil) {
        self.user = user
        self.host = host
        self.port = port
        self.identityFile = identityFile
    }

    public init(mount: RemoteMountSpec) {
        self.init(user: mount.user, host: mount.host, port: mount.port, identityFile: mount.identityFile)
    }

    /// `user@host`, or `host` without a user.
    public var destination: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    /// `destination`, with `:port` when the port is not 22.
    public var id: String {
        if let port, port != 22 { return "\(destination):\(port)" }
        return destination
    }
}

extension RemoteWorkspaceManager {

    static let recentHostsDefaultsKey = "Folio.RecentSSHHosts.v1"
    static let maxRecentHosts = 10

    /// Hosts used before, most recent first. Hosts of current mounts that were never recorded come last.
    public var recentHosts: [RemoteHostProfile] {
        var hosts = storedRecentHosts
        for mount in mounts.reversed() {
            let profile = RemoteHostProfile(mount: mount)
            if !hosts.contains(where: { $0.id == profile.id }) {
                hosts.append(profile)
            }
        }
        return hosts
    }

    /// Moves the host of `spec` to the front of `recentHosts`.
    public func recordRecentHost(_ spec: RemoteMountSpec) {
        let profile = RemoteHostProfile(mount: spec)
        var hosts = storedRecentHosts.filter { $0.id != profile.id }
        hosts.insert(profile, at: 0)
        guard let data = try? JSONEncoder().encode(Array(hosts.prefix(Self.maxRecentHosts))) else { return }
        objectWillChange.send()
        userDefaults.set(data, forKey: Self.recentHostsDefaultsKey)
    }

    private var storedRecentHosts: [RemoteHostProfile] {
        guard let data = userDefaults.data(forKey: Self.recentHostsDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteHostProfile].self, from: data)) ?? []
    }
}
