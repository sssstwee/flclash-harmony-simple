import { connection } from "@kit.NetworkKit";

export class Network {
  bearerTypes: connection.NetBearType[] = []
  dnses: connection.NetAddress[] = []
  capabilities: connection.NetCap[] = []
  linkFingerprint: string = ""
}
