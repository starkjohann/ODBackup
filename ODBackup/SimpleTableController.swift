import AppKit
import Foundation

// This class binds a table view to an array of objects. It does not support updates
// of the array, only setting the entire array. It is therefore suitable for arrays
// with little objects only.

@objc
class SimpleTableController: NSViewController, NSTableViewDataSource {

    fileprivate var isUsingKVC = false

    // We delegate the actual work to a concrete subclass so that type parameters can
    // be determined automatically by calling SimpleTableController.make() with appropriate
    // types.
    static func make<ObservedClass: _KeyValueCodingAndObserving & AnyObject, Value: Equatable>(tableView: NSTableView, observedObject: ObservedClass, observedKeyPath: ReferenceWritableKeyPath<ObservedClass, [Value]>) -> SimpleTableController {
        ConcreteSimpleTableController(tableView: tableView, observedObject: observedObject, observedKeyPath: observedKeyPath)
    }

    fileprivate init() {   // ensure that we have no public initializer
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int { abort() }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { abort() }

    // We are an NSViewController subclass in order to participate in the responder
    // chain so that we can implement copy/paste here.

    @objc func copy(_ sender: Any?) {
        copyToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        pasteFromPasteboard()
    }

    @objc func delete(_ sender: Any?) {
        deleteViaMenu()
    }

    fileprivate func copyToPasteboard() { abort() }
    fileprivate func pasteFromPasteboard() { abort() }
    fileprivate func deleteViaMenu() { abort() }

}

extension SimpleTableController {


}

// Intermediate super/subclass which introduces `Value` type parameter amd `objectsArray` property
private class IntermediateSimpleTableController<Value: Equatable>: SimpleTableController {

    var objectsArray: [Value] {
        get { [] }
        set { }
    }

}

private class ConcreteSimpleTableController<ObservedClass: _KeyValueCodingAndObserving & AnyObject, Value: Equatable>: IntermediateSimpleTableController<Value> {

    private let tableView: NSTableView
    private weak var observedObject: ObservedClass?
    private let observedKeyPath: ReferenceWritableKeyPath<ObservedClass, [Value]>
    private var observationHandle: NSKeyValueObservation?

    override var objectsArray: [Value] {
        get { observedObject?[keyPath: observedKeyPath] ?? [] }
        set { observedObject?[keyPath: observedKeyPath] = newValue }
    }

    init(tableView: NSTableView, observedObject: ObservedClass, observedKeyPath: ReferenceWritableKeyPath<ObservedClass, [Value]>) {
        self.tableView = tableView
        self.observedObject = observedObject
        self.observedKeyPath = observedKeyPath
        super.init()
        view = tableView
        tableView.dataSource = self
        observationHandle = observedObject.observe(observedKeyPath, options: [.initial, .old]) { [weak self] _, change in
            guard let self = self else { return }
            if self.isUsingKVC {
                // Defer because when we use `setValue(_:,forKey:)` in `RowWrapper`, this triggers KVO
                // and the table reload would use `value(forKey:)` within `setValue(_:,forKey:)`, which
                // triggers a Swift error.
                DispatchQueue.main.async {
                    self.reloadTable(oldValue: change.oldValue)
                }
            } else {
                self.reloadTable(oldValue: change.oldValue)
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func reloadTable(oldValue: [Value]?) {
        // try to preserve selection as much as possible
        let indexes = tableView.selectedRowIndexes
        let newIndexes: IndexSet
        if let oldValue {
            newIndexes = IndexSet(indexes.compactMap { $0 >= oldValue.count ? nil : objectsArray.firstIndex(of: oldValue[$0]) })
        } else {
            let count = objectsArray.count
            newIndexes = IndexSet(indexes.filter { $0 < count })
        }
        tableView.reloadData()
        tableView.selectRowIndexes(newIndexes, byExtendingSelection: false)
    }

    override func numberOfRows(in tableView: NSTableView) -> Int {
        objectsArray.count
    }

    override func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        RowWrapper.make(row: row, controller: self)
    }

    override func copyToPasteboard() {
        var rows = [String]()
        let array = objectsArray
        for index in tableView.selectedRowIndexes {
            if let object = array[index] as? StringRepresentable {
                rows.append(object.stringRepresentation)
            }
        }
        if !rows.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(rows.joined(separator: "\n"), forType: .string)
        }
    }

    override func pasteFromPasteboard() {
        if let StringRepresentableValue = Value.self as? StringRepresentable.Type {
            let pasteboard = NSPasteboard.general
            let pasteboardString = pasteboard.string(forType: .string)
            var array = objectsArray
            var indexesAdded = IndexSet()
            for line in pasteboardString?.components(separatedBy: CharacterSet.newlines) ?? [] {
                if !line.isEmpty, let object = StringRepresentableValue.make(representedString: line) {
                    indexesAdded.insert(array.count)
                    array.append(object as! Value)
                }
            }
            objectsArray = array    // updates the table view via KVO
            tableView.selectRowIndexes(indexesAdded, byExtendingSelection: false)
            if !indexesAdded.isEmpty {
                tableView.scrollRowToVisible(indexesAdded.last!)
            }
        }
    }

    override func deleteViaMenu() {
        let selectedIndexes = tableView.selectedRowIndexes
        guard !selectedIndexes.isEmpty else { return }
        var array = objectsArray
        // we must reverse so that removal of lower indexes does not change index
        // to element association
        for range in selectedIndexes.rangeView.reversed() {
            array.removeSubrange(range)
        }
        objectsArray = array
    }

}

@objc
private class RowWrapper: NSObject {

    static func make<Value: Equatable>(row: Int, controller: IntermediateSimpleTableController<Value>) -> RowWrapper {
        ConcreteRowWrapper(row: row, controller: controller)
    }

}

private class ConcreteRowWrapper<Value: Equatable>: RowWrapper {

    let row: Int
    weak var controller: IntermediateSimpleTableController<Value>?

    init(row: Int, controller: IntermediateSimpleTableController<Value>) {
        self.controller = controller
        self.row = row
    }

    override func value(forKey key: String) -> Any? {
        if key == "self" {
            return controller?.objectsArray[row]
        } else if let object = controller?.objectsArray[row] as? NSObject {
            return object.value(forKey: key)
        } else {
            fatalError("not an NSObject subclass in value(forKey:)")
        }
    }

    override func setValue(_ value: Any?, forKey key: String) {
        guard let controller = controller else { return }
        let oldIsUsingKVC = controller.isUsingKVC
        controller.isUsingKVC = true
        if key == "self" {
            var array = controller.objectsArray
            array[row] = value as! Value
            controller.objectsArray = array
        } else {
            let array = controller.objectsArray
            let object = array[row] as! NSObject
            object.setValue(value, forKey: key)
            controller.objectsArray = array // write back entire array
        }
        controller.isUsingKVC = oldIsUsingKVC
    }
}
