import Foundation
import Testing
@testable import PocketAgentCore

@Suite struct PairingImportTests {
    private func record() -> [String: Any] {
        // Synthetic bytes for format validation only; never a device credential.
        ["public_key": Data(repeating: 0, count: 32),
         "private_key": Data(repeating: 1, count: 32), "identifier": "test-host"]
    }
    private func encode(_ value: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }
    @Test func XMLAndBinaryRPRecordsAreAccepted() throws {
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            try PairingImport.validate(encode(record(), format: format))
        }
    }
    @Test func USBRecordGetsSpecificGuidance() throws {
        let data = try encode(["HostID": "test-host", "HostCertificate": Data([1, 2])])
        #expect(throws: PairingImport.ImportError.lockdownRecord) { try PairingImport.validate(data) }
    }
    @Test func InvalidRPFieldsAreRejected() throws {
        for field in ["public_key", "private_key", "identifier"] {
            var value = record(); value.removeValue(forKey: field)
            #expect(throws: PairingImport.ImportError.notRPRecord) { try PairingImport.validate(encode(value)) }
        }
        for count in [0, 31, 33] {
            var value = record(); value["private_key"] = Data(repeating: 1, count: count)
            #expect(throws: PairingImport.ImportError.notRPRecord) { try PairingImport.validate(encode(value)) }
        }
        var value = record(); value["identifier"] = " \n"
        #expect(throws: PairingImport.ImportError.notRPRecord) { try PairingImport.validate(encode(value)) }
    }
    @Test func OptionalIRKHasDefinedLength() throws {
        var value = record(); value["alt_irk"] = Data(repeating: 2, count: 16)
        try PairingImport.validate(encode(value))
        value["alt_irk"] = "not-data"
        #expect(throws: PairingImport.ImportError.notRPRecord) { try PairingImport.validate(encode(value)) }
    }
    @Test func UnrelatedAndOversizedFilesAreRejected() throws {
        #expect(throws: PairingImport.ImportError.notPlist) { try PairingImport.validate(Data("hello".utf8)) }
        #expect(throws: PairingImport.ImportError.notRPRecord) { try PairingImport.validate(encode(["unrelated": true])) }
        #expect(throws: PairingImport.ImportError.tooLarge) {
            try PairingImport.validate(Data(repeating: 0, count: PairingImport.maximumBytes + 1))
        }
    }
}
