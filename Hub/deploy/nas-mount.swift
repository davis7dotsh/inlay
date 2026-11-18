// Mount an SMB share at a fixed folder with NetFS, for a LaunchDaemon with no GUI login.
// A copy of agent-traces deploy/nas/nas-mount.swift.
//   nas-mount <smb url without password> <mount folder> <user> <password file> [--read-only]
// With --read-only the mount is read-only (MNT_RDONLY): no file call through it can write.
// The password is read from a mode 600 file inside this process and handed to NetFS in memory, so it is
// never on a command line and never in `ps`. The mount is soft: when the NAS is gone, file calls fail
// with an error instead of hanging, so the copy job sees a stale mount as an error.
import Foundation
import NetFS

let args = CommandLine.arguments
let readOnly = args.count == 6 && args[5] == "--read-only"
guard args.count == 5 || readOnly, let url = URL(string: args[1]) else {
  FileHandle.standardError.write("usage: nas-mount smb://host/share <mount folder> <user> <password file> [--read-only]\n".data(using: .utf8)!)
  exit(2)
}
let mountDir = URL(fileURLWithPath: args[2], isDirectory: true)
let user = args[3]
let attrs = try FileManager.default.attributesOfItem(atPath: args[4])
if let mode = attrs[.posixPermissions] as? Int, mode & 0o077 != 0 {
  FileHandle.standardError.write("nas-mount: \(args[4]) must be mode 600\n".data(using: .utf8)!)
  exit(2)
}
var password = try String(contentsOfFile: args[4], encoding: .utf8)
while password.hasSuffix("\n") || password.hasSuffix("\r") { password.removeLast() }

let openOptions = NSMutableDictionary()
openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
// A new SMB session each time, so a remount after a stale mount never reuses the old session.
openOptions[kNetFSForceNewSessionKey] = true
let mountOptions = NSMutableDictionary()
mountOptions[kNetFSMountAtMountDirKey] = true
mountOptions[kNetFSSoftMountKey] = true
mountOptions[kNetFSMountFlagsKey] = MNT_NOSUID | MNT_NODEV | MNT_DONTBROWSE | (readOnly ? MNT_RDONLY : 0)

var mounts: Unmanaged<CFArray>? = nil
let rc = NetFSMountURLSync(url as CFURL, mountDir as CFURL, user as CFString, password as CFString, openOptions, mountOptions, &mounts)
if rc != 0 {
  FileHandle.standardError.write("nas-mount: NetFSMountURLSync failed: \(rc) (\(String(cString: strerror(rc))))\n".data(using: .utf8)!)
  exit(1)
}
let points = (mounts?.takeRetainedValue() as? [String]) ?? []
print("nas-mount: mounted \(args[1]) at \(points.joined(separator: ", "))")
