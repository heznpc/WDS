import Darwin
import Foundation

/// A process-scoped lock, shared by every copy of this app for the current user.
/// The empty file stays in place so two launches cannot lock different inodes.
final class SingleInstanceLock {
    private var descriptor: Int32 = -1

    func acquire() -> Bool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.heznpc.WDS.instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
