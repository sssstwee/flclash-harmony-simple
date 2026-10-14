import { connection } from "@kit.NetworkKit";
import { Network } from "../models/Network"

// This observer belongs to VpnExtAbility, not the Flutter lifecycle. The existing
// DNS bridge also carries network identity, including handoffs with the same DNS.
export default class NetworkManager {
  private netConnection: connection.NetConnection | undefined
  private networkMap: Map<number, Network> = new Map<number, Network>()
  private previousFingerprint: string = ""
  private generation: number = 0
  private callback: ((s: string) => void) | undefined
  private subscription: Promise<void> | undefined

  private asSocketAddressText(address: connection.NetAddress, port: number): string {
    return address.family === 2 ? `[${address.address}]:${port}` : `${address.address}:${port}`
  }

  private handleNetworkUpdate(): void {
    if (!this.callback) return
    // Trust the actual system default, rather than selecting the numerically
    // highest bearer (which could be our own VPN and cause a feedback loop).
    let netId = 0
    try { netId = connection.getDefaultNetSync().netId } catch (_) { return }
    const best = this.networkMap.get(netId)
    const online = netId !== 0 && best !== undefined
    const capabilities = best?.capabilities ?? []
    const portal = capabilities.includes(connection.NetCap.NET_CAPABILITY_PORTAL)
    const validated = capabilities.includes(connection.NetCap.NET_CAPABILITY_VALIDATED)
    const dnsList = Array.from(new Set((best?.dnses ?? [])
      .map((address: connection.NetAddress) => this.asSocketAddressText(address, 53)))).sort()
    const fingerprint = `${netId}|${online}|${portal}|${validated}|${best?.bearerTypes.join(',') ?? ''}|${best?.linkFingerprint ?? ''}|${dnsList.join(',')}`
    if (fingerprint === this.previousFingerprint) return
    this.previousFingerprint = fingerprint
    this.callback(JSON.stringify({
      kind: "network-change", dns: dnsList, online,
      captivePortal: portal, validated,
    }))
  }

  subscribe(callback: (s: string) => void): Promise<void> {
    if (this.subscription) return this.subscription
    this.callback = callback
    this.previousFingerprint = ""
    this.networkMap.clear()
    const generation = ++this.generation
    const observer = connection.createNetConnection()
    this.netConnection = observer
    const current = (): boolean => generation === this.generation
    observer.on("netAvailable", (handle: connection.NetHandle) => {
      if (!current() || !handle.netId) return
      if (!this.networkMap.has(handle.netId)) this.networkMap.set(handle.netId, new Network())
      this.handleNetworkUpdate()
    })
    observer.on("netCapabilitiesChange", (info: connection.NetCapabilityInfo) => {
      if (!current() || !info.netHandle.netId) return
      const network = this.networkMap.get(info.netHandle.netId) ?? new Network()
      network.bearerTypes = info.netCap.bearerTypes
      network.capabilities = info.netCap.networkCap ?? []
      this.networkMap.set(info.netHandle.netId, network)
      this.handleNetworkUpdate()
    })
    observer.on("netConnectionPropertiesChange", (info: connection.NetConnectionPropertyInfo) => {
      if (!current() || !info.netHandle.netId) return
      const network = this.networkMap.get(info.netHandle.netId) ?? new Network()
      const props = info.connectionProperties
      network.dnses = props.dnses ?? []
      network.linkFingerprint = `${props.interfaceName}|${(props.linkAddresses ?? [])
        .map((link: connection.LinkAddress) => `${link.address.address}/${link.prefixLength}`).sort().join(',')}`
      this.networkMap.set(info.netHandle.netId, network)
      this.handleNetworkUpdate()
    })
    observer.on("netLost", (handle: connection.NetHandle) => {
      if (!current()) return
      this.networkMap.delete(handle.netId)
      this.handleNetworkUpdate()
    })
    this.subscription = new Promise<void>((resolve, reject) => {
      observer.register((err: Error) => {
        if (err) {
          if (current()) {
            this.callback = undefined
            this.subscription = undefined
            this.netConnection = undefined
            ++this.generation
          }
          reject(err)
        } else {
          resolve()
        }
      })
    })
    return this.subscription
  }

  // Read OS state after registration rather than assuming the first callback
  // has arrived. These are local NetworkKit reads, not Internet health probes.
  refreshSnapshot(): Promise<void> {
    const generation = this.generation
    return (this.subscription ?? Promise.resolve()).then(() => {
      if (generation !== this.generation || !this.callback) return
      const handle = connection.getDefaultNetSync()
      if (handle.netId !== 0) {
        const capabilities = connection.getNetCapabilitiesSync(handle)
        const properties = connection.getConnectionPropertiesSync(handle)
        const network = new Network()
        network.bearerTypes = capabilities.bearerTypes
        network.capabilities = capabilities.networkCap ?? []
        network.dnses = properties.dnses ?? []
        network.linkFingerprint = `${properties.interfaceName}|${(properties.linkAddresses ?? [])
          .map((link: connection.LinkAddress) => `${link.address.address}/${link.prefixLength}`).sort().join(',')}`
        this.networkMap.set(handle.netId, network)
      }
      this.handleNetworkUpdate()
    })
  }

  unsubscribe(): Promise<void> {
    ++this.generation
    // Cancel probes before unregistering; late callbacks from this observer are
    // ignored even if stop/start races the asynchronous unregister completion.
    this.callback?.(JSON.stringify({
      kind: "network-stop",
    }))
    this.callback = undefined
    const registration = this.subscription
    this.subscription = undefined
    this.networkMap.clear()
    this.previousFingerprint = ""
    const observer = this.netConnection
    this.netConnection = undefined
    if (!observer) return Promise.resolve()
    // Unregister only after an in-flight registration settles. Otherwise a late
    // successful register could leave a stopped observer registered forever.
    return (registration ?? Promise.resolve()).then(() => {
      return new Promise<void>((resolve, reject) => {
        observer.unregister((err: Error) => err ? reject(err) : resolve())
      })
    }, () => Promise.resolve())
  }
}
