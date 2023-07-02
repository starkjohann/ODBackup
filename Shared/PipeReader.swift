import Foundation
import os

class PipeReader {
    private let pipe: Pipe = Pipe()
    private var observationHandle: NSObjectProtocol?
    var fileHandleForWriting: FileHandle { pipe.fileHandleForWriting }

    init(dataHandler: @escaping (Data) -> Void) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        // Handle reading in a separate thread instead of using `fileHandle.waitForDataInBackgroundAndNotify()`
        // because the latter is not sufficiently efficient to handle file listing output from borg.
        DispatchQueue.global().async {
            let bufferSize = 16384
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
            while true {
                // `fd` should be in blocking I/O mode
                let readCount = read(fd, buffer, bufferSize)
                if readCount > 0 {
                    dataHandler(Data(bytes: buffer, count: readCount))
                } else {
                    if readCount < 0 {
                        os_log("PipeReader: stop reading due to read error: \(errno)")
                    }
                    break
                }
            }
        }
    }

    deinit {
        if let observationHandle = observationHandle {
            NotificationCenter.default.removeObserver(observationHandle)
        }
    }

}
