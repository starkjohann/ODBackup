import Foundation


@objc
class FileNode: NSObject {

    private static var tabCharacterSet = CharacterSet(charactersIn: "\t")
    private static var slashCharacterSet = CharacterSet(charactersIn: "/")

    @objc dynamic var mode = ""
    @objc dynamic var owner = ""
    @objc dynamic var group = ""
    @objc dynamic var size = Int64(0)
    @objc dynamic var mtime = ""
    @objc dynamic var name: String
    var children = [FileNode]()
    var lastIndexFound = -1

    @objc dynamic var displayString: String { name }

    var sizeDisplayString: String {
        Formatters.string(fromByteCount: deepSize)
    }

    var fileCountDisplayString: String {
        let deepCount = deepCount
        if deepCount > 0 {
            return Formatters.string(fromFileCount: Int64(deepCount)) + " files"
        } else {
            return ""
        }
    }

    var mtimeDisplayString: String {
        if let match = mtime.firstMatch(of: /^[a-zA-Z]+, (.*)$/) {
            return String(match.output.1)
        } else {
            return mtime
        }
    }

    var deepCount: Int {
        children.count + children.reduce(into: 0) { partialResult, node in
            partialResult += node.deepCount
        }
    }

    var deepSize: Int64 {
        size + children.reduce(into: 0) { partialResult, node in
            partialResult += node.deepSize
        }
    }

    override var description: String {
        "\(mode) \(owner) \(group) \(size) \(mtime) \(name)"
    }

    init(name: String) {
        self.name = name
    }

    func reset() {
        children = []
        lastIndexFound = -1
        name = ""
    }

    func addChildren(listingLines: [String], reloadItemCallback: @escaping (FileNode) -> Void) {
        var lastDirectory: String?
        var lastParent: FileNode?
        for line in listingLines {
            var line = line
            let fields = line.splitAtCharacter("\t")
            guard fields.count >= 6 else {
                continue
            }
            let path = fields[5]
            var directory: String
            let filename: String
            if let lastSlash = path.lastIndex(of: "/") {
                directory = String(path.prefix(upTo: lastSlash))
                filename = String(path.suffix(from: path.index(after: lastSlash)))
            } else {
                directory = ""
                filename = path
            }
            if filename == "." {
                continue
            }
            let parent: FileNode
            if let lastDirectory, directory == lastDirectory {
                parent = lastParent!
            } else {
                let directoryComponents = directory.splitAtCharacter("/")
                parent = childNodeWithPath(directoryComponents, reloadItemCallback: reloadItemCallback)
                if let lastParent {
                    reloadItemCallback(lastParent)
                }
                lastDirectory = String(directory)
                lastParent = parent
            }
            let child = parent.childNodeWithPath([filename], reloadItemCallback: nil)
            child.mode = String(fields[0])
            child.owner = String(fields[1])
            child.group = String(fields[2])
            child.size = Int64(fields[3]) ?? 0
            child.mtime = String(fields[4])
        }
        if let lastParent {
            reloadItemCallback(lastParent)
        }
    }

    func childNodeWithPath(_ path: [String], reloadItemCallback: ((FileNode) -> Void)?) -> FileNode {
        if path.isEmpty {
            return self
        }
        var path = path
        let childName = String(path.removeFirst())
        let nextChild: FileNode
        // shortcut: assume that we search the same item over and over again (e.g. in a long path)
        if lastIndexFound >= 0, case let child = children[lastIndexFound], child.name == childName {
            nextChild = child
        } else {
            let index = children.binarySearch { $0.name < childName }
            if index >= children.count {
                let child = FileNode(name: childName)
                children.append(child)
                nextChild = child
                reloadItemCallback?(self)
            } else {
                if case let child = children[index], child.name == childName {
                    nextChild = child
                    lastIndexFound = index
                } else {
                    let child = FileNode(name: childName)
                    children.insert(child, at: index)
                    nextChild = child
                    reloadItemCallback?(self)
                }
            }
        }
        return nextChild.childNodeWithPath(path, reloadItemCallback: reloadItemCallback)
    }

}

private extension Array {

    // returns insertion point for reference element
    func binarySearch(isLessThanReference: (Element) -> Bool) -> Index {
        var low = 0
        var high = endIndex
        while low != high {
            let mid = low + (high - low) / 2
            if isLessThanReference(self[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private extension String {


//    // semi-efficient implementation of string splitting
//    func splitAtCharacter(_ character: Character) -> [String] {
//        guard !isEmpty else {
//            return []
//        }
//        let c = character.utf8.first!
//        return utf8.split(separator: c, omittingEmptySubsequences: false).map { String($0)! }
//    }

    // This is the fastest function to split an UTF-8 string at ASCII characters which I could come up with.
    // Unfortunately, `String.withUTF8()` is declared mutating, so we must declare the function mutating.
    mutating func splitAtCharacter(_ character: Character) -> [String] {
        guard !isEmpty else {
            return []
        }
        let c = character.utf8.first!
        return withUTF8 { bufferPointer in
            var strings = [String]()
            let count = bufferPointer.count
            let ptr = bufferPointer.baseAddress!
            var indexAfterMatch = 0
            var i = 0
            while i < count {
                if ptr[i] == c {
                    let s = String(data: Data(bytes: ptr + indexAfterMatch, count: i - indexAfterMatch), encoding: .utf8) ?? "<invalid string>"
                    strings.append(s)
                    indexAfterMatch = i + 1
                }
                i += 1
            }
            let s = String(data: Data(bytes: ptr + indexAfterMatch, count: i - indexAfterMatch), encoding: .utf8) ?? "<invalid string>"
            strings.append(s)
            return strings
        }
    }

}
