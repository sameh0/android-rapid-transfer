import Foundation

/// DeviceInfo dataset (PIMA 15740 §5.5.1).
public struct PTPDeviceInfo: Equatable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDesc: String
    public var functionalMode: UInt16
    public var operationsSupported: [UInt16]
    public var eventsSupported: [UInt16]
    public var devicePropertiesSupported: [UInt16]
    public var captureFormats: [UInt16]
    public var playbackFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(
        standardVersion: UInt16 = 100, vendorExtensionID: UInt32 = 6, vendorExtensionVersion: UInt16 = 100,
        vendorExtensionDesc: String = "", functionalMode: UInt16 = 0,
        operationsSupported: [UInt16] = [], eventsSupported: [UInt16] = [],
        devicePropertiesSupported: [UInt16] = [], captureFormats: [UInt16] = [],
        playbackFormats: [UInt16] = [], manufacturer: String = "", model: String = "",
        deviceVersion: String = "", serialNumber: String = ""
    ) {
        self.standardVersion = standardVersion
        self.vendorExtensionID = vendorExtensionID
        self.vendorExtensionVersion = vendorExtensionVersion
        self.vendorExtensionDesc = vendorExtensionDesc
        self.functionalMode = functionalMode
        self.operationsSupported = operationsSupported
        self.eventsSupported = eventsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
        self.captureFormats = captureFormats
        self.playbackFormats = playbackFormats
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
    }

    public func supports(_ operation: UInt16) -> Bool { operationsSupported.contains(operation) }

    public static func decode(_ bytes: [UInt8]) throws -> PTPDeviceInfo {
        var r = PTPReader(bytes)
        return PTPDeviceInfo(
            standardVersion: try r.u16("StandardVersion"),
            vendorExtensionID: try r.u32("VendorExtensionID"),
            vendorExtensionVersion: try r.u16("VendorExtensionVersion"),
            vendorExtensionDesc: try r.string("VendorExtensionDesc"),
            functionalMode: try r.u16("FunctionalMode"),
            operationsSupported: try r.u16Array("OperationsSupported"),
            eventsSupported: try r.u16Array("EventsSupported"),
            devicePropertiesSupported: try r.u16Array("DevicePropertiesSupported"),
            captureFormats: try r.u16Array("CaptureFormats"),
            playbackFormats: try r.u16Array("PlaybackFormats"),
            manufacturer: try r.string("Manufacturer"),
            model: try r.string("Model"),
            deviceVersion: try r.string("DeviceVersion"),
            serialNumber: try r.string("SerialNumber")
        )
    }

    public func encode() throws -> [UInt8] {
        var w = PTPWriter()
        w.u16(standardVersion)
        w.u32(vendorExtensionID)
        w.u16(vendorExtensionVersion)
        try w.string(vendorExtensionDesc)
        w.u16(functionalMode)
        w.u16Array(operationsSupported)
        w.u16Array(eventsSupported)
        w.u16Array(devicePropertiesSupported)
        w.u16Array(captureFormats)
        w.u16Array(playbackFormats)
        try w.string(manufacturer)
        try w.string(model)
        try w.string(deviceVersion)
        try w.string(serialNumber)
        return w.bytes
    }
}

/// StorageInfo dataset (PIMA 15740 §5.5.3).
public struct PTPStorageInfo: Equatable, Sendable {
    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpaceInBytes: UInt64
    public var freeSpaceInObjects: UInt32
    public var storageDescription: String
    public var volumeIdentifier: String

    public init(
        storageType: UInt16 = 3, filesystemType: UInt16 = 2, accessCapability: UInt16 = 0,
        maxCapacity: UInt64 = 0, freeSpaceInBytes: UInt64 = 0, freeSpaceInObjects: UInt32 = 0xFFFF_FFFF,
        storageDescription: String = "", volumeIdentifier: String = ""
    ) {
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity
        self.freeSpaceInBytes = freeSpaceInBytes
        self.freeSpaceInObjects = freeSpaceInObjects
        self.storageDescription = storageDescription
        self.volumeIdentifier = volumeIdentifier
    }

    public static func decode(_ bytes: [UInt8]) throws -> PTPStorageInfo {
        var r = PTPReader(bytes)
        return PTPStorageInfo(
            storageType: try r.u16("StorageType"),
            filesystemType: try r.u16("FilesystemType"),
            accessCapability: try r.u16("AccessCapability"),
            maxCapacity: try r.u64("MaxCapacity"),
            freeSpaceInBytes: try r.u64("FreeSpaceInBytes"),
            freeSpaceInObjects: try r.u32("FreeSpaceInObjects"),
            storageDescription: try r.string("StorageDescription"),
            volumeIdentifier: try r.string("VolumeIdentifier")
        )
    }

    public func encode() throws -> [UInt8] {
        var w = PTPWriter()
        w.u16(storageType)
        w.u16(filesystemType)
        w.u16(accessCapability)
        w.u64(maxCapacity)
        w.u64(freeSpaceInBytes)
        w.u32(freeSpaceInObjects)
        try w.string(storageDescription)
        try w.string(volumeIdentifier)
        return w.bytes
    }
}

/// ObjectInfo dataset (PIMA 15740 §5.5.2). Dates are kept as the raw PTP
/// DateTime strings; ``PTPDateTime/parse(_:)`` converts them.
public struct PTPObjectInfo: Equatable, Sendable {
    public var storageID: UInt32
    public var objectFormat: UInt16
    public var protectionStatus: UInt16
    /// 32-bit size; 0xFFFFFFFF means ">= 4 GB, ask ObjectSize (0xDC04)".
    public var compressedSize: UInt32
    public var thumbFormat: UInt16
    public var thumbCompressedSize: UInt32
    public var thumbPixWidth: UInt32
    public var thumbPixHeight: UInt32
    public var imagePixWidth: UInt32
    public var imagePixHeight: UInt32
    public var imageBitDepth: UInt32
    public var parentObject: UInt32
    public var associationType: UInt16
    public var associationDesc: UInt32
    public var sequenceNumber: UInt32
    public var filename: String
    public var captureDate: String
    public var modificationDate: String
    public var keywords: String

    public init(
        storageID: UInt32 = 0, objectFormat: UInt16 = PTPObjectFormat.undefined, protectionStatus: UInt16 = 0,
        compressedSize: UInt32 = 0, thumbFormat: UInt16 = 0, thumbCompressedSize: UInt32 = 0,
        thumbPixWidth: UInt32 = 0, thumbPixHeight: UInt32 = 0, imagePixWidth: UInt32 = 0,
        imagePixHeight: UInt32 = 0, imageBitDepth: UInt32 = 0, parentObject: UInt32 = 0,
        associationType: UInt16 = 0, associationDesc: UInt32 = 0, sequenceNumber: UInt32 = 0,
        filename: String = "", captureDate: String = "", modificationDate: String = "", keywords: String = ""
    ) {
        self.storageID = storageID
        self.objectFormat = objectFormat
        self.protectionStatus = protectionStatus
        self.compressedSize = compressedSize
        self.thumbFormat = thumbFormat
        self.thumbCompressedSize = thumbCompressedSize
        self.thumbPixWidth = thumbPixWidth
        self.thumbPixHeight = thumbPixHeight
        self.imagePixWidth = imagePixWidth
        self.imagePixHeight = imagePixHeight
        self.imageBitDepth = imageBitDepth
        self.parentObject = parentObject
        self.associationType = associationType
        self.associationDesc = associationDesc
        self.sequenceNumber = sequenceNumber
        self.filename = filename
        self.captureDate = captureDate
        self.modificationDate = modificationDate
        self.keywords = keywords
    }

    public var isFolder: Bool { objectFormat == PTPObjectFormat.association }

    /// Builds the ObjectInfo a host sends with SendObjectInfo. Sizes of 4 GB
    /// and up are sent as 0xFFFFFFFF, the MTP value for a size that does not
    /// fit 32 bits.
    public static func forUpload(filename: String, size: UInt64, format: UInt16 = PTPObjectFormat.undefined,
                                 modificationDate: Date? = nil, storageID: UInt32 = 0,
                                 parentObject: UInt32 = 0) -> PTPObjectInfo {
        PTPObjectInfo(
            storageID: storageID, objectFormat: format,
            compressedSize: size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(size),
            parentObject: parentObject,
            associationType: format == PTPObjectFormat.association ? PTPAssociationType.genericFolder : 0,
            filename: filename,
            modificationDate: modificationDate.map(PTPDateTime.format) ?? ""
        )
    }

    public static func decode(_ bytes: [UInt8]) throws -> PTPObjectInfo {
        var r = PTPReader(bytes)
        return PTPObjectInfo(
            storageID: try r.u32("StorageID"),
            objectFormat: try r.u16("ObjectFormat"),
            protectionStatus: try r.u16("ProtectionStatus"),
            compressedSize: try r.u32("ObjectCompressedSize"),
            thumbFormat: try r.u16("ThumbFormat"),
            thumbCompressedSize: try r.u32("ThumbCompressedSize"),
            thumbPixWidth: try r.u32("ThumbPixWidth"),
            thumbPixHeight: try r.u32("ThumbPixHeight"),
            imagePixWidth: try r.u32("ImagePixWidth"),
            imagePixHeight: try r.u32("ImagePixHeight"),
            imageBitDepth: try r.u32("ImageBitDepth"),
            parentObject: try r.u32("ParentObject"),
            associationType: try r.u16("AssociationType"),
            associationDesc: try r.u32("AssociationDesc"),
            sequenceNumber: try r.u32("SequenceNumber"),
            filename: try r.string("Filename"),
            captureDate: try r.string("CaptureDate"),
            modificationDate: try r.string("ModificationDate"),
            keywords: try r.string("Keywords")
        )
    }

    public func encode() throws -> [UInt8] {
        var w = PTPWriter()
        w.u32(storageID)
        w.u16(objectFormat)
        w.u16(protectionStatus)
        w.u32(compressedSize)
        w.u16(thumbFormat)
        w.u32(thumbCompressedSize)
        w.u32(thumbPixWidth)
        w.u32(thumbPixHeight)
        w.u32(imagePixWidth)
        w.u32(imagePixHeight)
        w.u32(imageBitDepth)
        w.u32(parentObject)
        w.u16(associationType)
        w.u32(associationDesc)
        w.u32(sequenceNumber)
        try w.string(filename)
        try w.string(captureDate)
        try w.string(modificationDate)
        try w.string(keywords)
        return w.bytes
    }
}

/// A typed PTP value (ObjectPropList elements, GetObjectPropValue).
public enum PTPValue: Equatable, Sendable {
    /// DTC_UNDEF: the device has no value. Carries no payload.
    case undefined
    case int8(Int8), uint8(UInt8), int16(Int16), uint16(UInt16)
    case int32(Int32), uint32(UInt32), int64(Int64), uint64(UInt64)
    /// 128-bit values as their 16 little-endian bytes.
    case int128([UInt8]), uint128([UInt8])
    case string(String)
    /// Array datatypes: element type and the raw element bytes.
    case array(elementType: UInt16, count: Int, bytes: [UInt8])

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// Any integer value that fits in UInt64 (negative values yield nil).
    public var unsignedValue: UInt64? {
        switch self {
        case let .uint8(v): return UInt64(v)
        case let .uint16(v): return UInt64(v)
        case let .uint32(v): return UInt64(v)
        case let .uint64(v): return v
        case let .int8(v): return v >= 0 ? UInt64(v) : nil
        case let .int16(v): return v >= 0 ? UInt64(v) : nil
        case let .int32(v): return v >= 0 ? UInt64(v) : nil
        case let .int64(v): return v >= 0 ? UInt64(v) : nil
        default: return nil
        }
    }

    /// Reads a value of `dataType`. Unknown datatypes throw, since the element
    /// width, and so the rest of the stream, would be unknowable.
    public static func decode(_ dataType: UInt16, from r: inout PTPReader) throws -> PTPValue {
        switch dataType {
        case PTPDataType.undefined: return .undefined
        case PTPDataType.int8: return .int8(try r.i8())
        case PTPDataType.uint8: return .uint8(try r.u8())
        case PTPDataType.int16: return .int16(try r.i16())
        case PTPDataType.uint16: return .uint16(try r.u16())
        case PTPDataType.int32: return .int32(try r.i32())
        case PTPDataType.uint32: return .uint32(try r.u32())
        case PTPDataType.int64: return .int64(try r.i64())
        case PTPDataType.uint64: return .uint64(try r.u64())
        case PTPDataType.int128: return .int128(try r.u128())
        case PTPDataType.uint128: return .uint128(try r.u128())
        // ORDER MATTERS: STR is 0xFFFF, which also has the array bit set.
        case PTPDataType.string: return .string(try r.string())
        default: break
        }
        if dataType & PTPDataType.arrayMask != 0 {
            let elementType = dataType & ~PTPDataType.arrayMask
            guard let width = PTPDataType.scalarSize(elementType) else {
                throw PTPDecodingError(String(format: "unknown array datatype 0x%04X", dataType))
            }
            let count = Int(try r.u32("array count"))
            guard count <= r.remaining / width else {
                throw PTPDecodingError("array of \(count) element(s) exceeds remaining \(r.remaining) byte(s)")
            }
            return .array(elementType: elementType, count: count, bytes: try r.raw(count * width, "array payload"))
        }
        throw PTPDecodingError(String(format: "unknown datatype 0x%04X", dataType))
    }

    public func encode(into w: inout PTPWriter) throws {
        switch self {
        case .undefined: break
        case let .int8(v): w.i8(v)
        case let .uint8(v): w.u8(v)
        case let .int16(v): w.i16(v)
        case let .uint16(v): w.u16(v)
        case let .int32(v): w.i32(v)
        case let .uint32(v): w.u32(v)
        case let .int64(v): w.i64(v)
        case let .uint64(v): w.u64(v)
        case let .int128(b), let .uint128(b):
            guard b.count == 16 else { throw PTPDecodingError("128-bit value must be 16 bytes") }
            w.raw(b)
        case let .string(s): try w.string(s)
        case let .array(_, count, bytes):
            w.u32(UInt32(count))
            w.raw(bytes)
        }
    }

    /// The PTP datatype code for this value.
    public var dataType: UInt16 {
        switch self {
        case .undefined: return PTPDataType.undefined
        case .int8: return PTPDataType.int8
        case .uint8: return PTPDataType.uint8
        case .int16: return PTPDataType.int16
        case .uint16: return PTPDataType.uint16
        case .int32: return PTPDataType.int32
        case .uint32: return PTPDataType.uint32
        case .int64: return PTPDataType.int64
        case .uint64: return PTPDataType.uint64
        case .int128: return PTPDataType.int128
        case .uint128: return PTPDataType.uint128
        case .string: return PTPDataType.string
        case let .array(elementType, _, _): return elementType | PTPDataType.arrayMask
        }
    }
}

/// One element of an ObjectPropList.
public struct MTPObjectPropListElement: Equatable, Sendable {
    public var handle: UInt32
    public var propertyCode: UInt16
    public var dataType: UInt16
    public var value: PTPValue

    public init(handle: UInt32, propertyCode: UInt16, value: PTPValue) {
        self.handle = handle
        self.propertyCode = propertyCode
        self.dataType = value.dataType
        self.value = value
    }
}

/// ObjectPropList dataset (MTP 1.1 §5.4.3.1): u32 count, then per element
/// u32 handle, u16 property code, u16 datatype, value.
public enum MTPObjectPropList {
    public static func decode(_ bytes: [UInt8]) throws -> [MTPObjectPropListElement] {
        var r = PTPReader(bytes)
        let count = Int(try r.u32("ObjectPropList count"))
        // Each element is at least 8 bytes (handle, code, datatype).
        guard count <= r.remaining / 8 else {
            throw PTPDecodingError("ObjectPropList count \(count) exceeds remaining \(r.remaining) byte(s)")
        }
        var elements: [MTPObjectPropListElement] = []
        elements.reserveCapacity(count)
        for index in 0..<count {
            do {
                let handle = try r.u32("handle")
                let code = try r.u16("property code")
                let type = try r.u16("datatype")
                let value = try PTPValue.decode(type, from: &r)
                var element = MTPObjectPropListElement(handle: handle, propertyCode: code, value: value)
                element.dataType = type
                elements.append(element)
            } catch let error as PTPDecodingError {
                throw PTPDecodingError("ObjectPropList element \(index): \(error.message)")
            }
        }
        return elements
    }

    public static func encode(_ elements: [MTPObjectPropListElement]) throws -> [UInt8] {
        var w = PTPWriter()
        w.u32(UInt32(elements.count))
        for element in elements {
            w.u32(element.handle)
            w.u16(element.propertyCode)
            w.u16(element.dataType)
            try element.value.encode(into: &w)
        }
        return w.bytes
    }
}
