import Foundation

protocol StringRepresentable {

    var stringRepresentation: String { get }

    static func make(representedString: String) -> Self?

}

extension String: StringRepresentable {

    var stringRepresentation: String { self }

    static func make(representedString: String) -> Self? {
        representedString
    }

}
