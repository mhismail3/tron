import Darwin
import Foundation

/// Optional evidence goes only to a newly allocated private temporary directory.
/// There is no caller-selected path, replacement, recursive cleanup, or runtime
/// store access. Parent retention is a separate, explicit operation.
final class CaptureQualificationImages {
    let path: String
    private let descriptor: Int32
    private var written = Set<CaptureQualificationStage>()
    private var totalBytes = 0

    init() throws {
        var template = Array("/private/tmp/tron-capture-qualification.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw CaptureQualificationFailure.outputUnavailable }
        path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard opened >= 0 else { throw CaptureQualificationFailure.outputUnavailable }
        guard fstat(opened, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else {
            close(opened)
            throw CaptureQualificationFailure.outputUnavailable
        }
        descriptor = opened
    }

    func write(_ bytes: Data, stage: CaptureQualificationStage) throws {
        guard written.count < 4, !written.contains(stage), (1...2 * 1_024 * 1_024).contains(bytes.count),
              totalBytes <= 8 * 1_024 * 1_024 - bytes.count else { throw CaptureQualificationFailure.outputUnavailable }
        // Verify the reported path still names our pinned directory before writing.
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0, lstat(path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              named.st_mode & S_IFMT == S_IFDIR, named.st_uid == getuid(), named.st_mode & 0o777 == 0o700 else {
            throw CaptureQualificationFailure.outputUnavailable
        }
        let file = openat(descriptor, stage.rawValue + ".jpg", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CaptureQualificationFailure.outputUnavailable }
        var okay = true
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { okay = false; break }
                offset += count
            }
        }
        if fsync(file) != 0 { okay = false }
        if close(file) != 0 { okay = false } // An uncertain close is never retried.
        guard okay else { throw CaptureQualificationFailure.outputUnavailable }
        written.insert(stage); totalBytes += bytes.count
    }

    deinit { close(descriptor) } // Evidence is retained, never recursively deleted.
}
