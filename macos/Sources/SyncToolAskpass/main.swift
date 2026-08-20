import Foundation
#if canImport(Darwin)
import Darwin
#endif

// SSH_ASKPASS-Helfer. ssh ruft ihn mit dem Prompt als argv[1] auf und erwartet
// die Antwort auf stdout. Das Passwort kommt ueber einen Unix-Domain-Socket,
// dessen Pfad SyncTool in SYNCTOOL_PW_SOCK hinterlegt.

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

// Host-Key-Rueckfragen laufen ueber denselben Kanal. Darauf antwortet der
// Helfer nie, sonst wuerde er das Passwort als Bestaetigung ausgeben.
let lowered = prompt.lowercased()
for marker in ["yes/no", "fingerprint", "authenticity of host", "(yes/no" ] where lowered.contains(marker) {
    FileHandle.standardError.write(Data("SyncToolAskpass: Host-Key-Rückfrage wird nicht beantwortet.\n".utf8))
    exit(1)
}

guard let socketPath = ProcessInfo.processInfo.environment["SYNCTOOL_PW_SOCK"] else {
    FileHandle.standardError.write(Data("SyncToolAskpass: SYNCTOOL_PW_SOCK fehlt.\n".utf8))
    exit(1)
}

guard socketPath.utf8.count < 104 else {
    FileHandle.standardError.write(Data("SyncToolAskpass: Socket-Pfad zu lang.\n".utf8))
    exit(1)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    FileHandle.standardError.write(Data("SyncToolAskpass: socket() fehlgeschlagen.\n".utf8))
    exit(1)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let pathBytes = Array(socketPath.utf8)
let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
        for (index, byte) in pathBytes.enumerated() { dst[index] = CChar(bitPattern: byte) }
        dst[pathBytes.count] = 0
    }
}

let connected = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    FileHandle.standardError.write(Data("SyncToolAskpass: connect() fehlgeschlagen.\n".utf8))
    close(fd)
    exit(1)
}

var received = [UInt8]()
var chunk = [UInt8](repeating: 0, count: 512)
while true {
    let count = read(fd, &chunk, chunk.count)
    if count > 0 {
        received.append(contentsOf: chunk[0..<count])
    } else if count == 0 {
        break
    } else if errno == EINTR {
        continue
    } else {
        break
    }
}
close(fd)

guard !received.isEmpty else {
    FileHandle.standardError.write(Data("SyncToolAskpass: kein Passwort erhalten.\n".utf8))
    exit(1)
}

// ssh erwartet genau eine Zeile.
var output = received
while let last = output.last, last == 0x0A || last == 0x0D { output.removeLast() }
output.append(0x0A)
FileHandle.standardOutput.write(Data(output))
exit(0)
