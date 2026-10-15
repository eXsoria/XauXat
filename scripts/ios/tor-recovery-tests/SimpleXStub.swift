public struct NetCfg { public init() {} }
public var publishedTorPort: UInt16?
public var publishedPorts: [UInt16] = []
public func getNetCfg() -> NetCfg { NetCfg() }
public func isXauXatManagedTorConfig(_ cfg: NetCfg) -> Bool { publishedTorPort != nil }
public func setXauXatTorSocksPort(_ port: UInt16?) {
    publishedTorPort = port
    if let port { publishedPorts.append(port) }
}
