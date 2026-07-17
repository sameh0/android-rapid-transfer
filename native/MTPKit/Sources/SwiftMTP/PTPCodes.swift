import Foundation

/// PTP/MTP operation codes used by this stack (PIMA 15740 and MTP 1.1, plus
/// the Android extensions).
public enum PTPOperation {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getStorageInfo: UInt16 = 0x1005
    public static let getNumObjects: UInt16 = 0x1006
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let deleteObject: UInt16 = 0x100B
    public static let sendObjectInfo: UInt16 = 0x100C
    public static let sendObject: UInt16 = 0x100D
    public static let getPartialObject: UInt16 = 0x101B

    public static let getObjectPropsSupported: UInt16 = 0x9801
    public static let getObjectPropDesc: UInt16 = 0x9802
    public static let getObjectPropValue: UInt16 = 0x9803
    public static let setObjectPropValue: UInt16 = 0x9804
    public static let getObjectPropList: UInt16 = 0x9805

    /// Android: GetPartialObject with a 64-bit offset (handle, offset low,
    /// offset high, max bytes).
    public static let androidGetPartialObject64: UInt16 = 0x95C1
    public static let androidSendPartialObject: UInt16 = 0x95C2
    public static let androidTruncateObject: UInt16 = 0x95C3
    public static let androidBeginEditObject: UInt16 = 0x95C4
    public static let androidEndEditObject: UInt16 = 0x95C5

    public static func name(_ code: UInt16) -> String {
        names[code] ?? String(format: "Operation 0x%04X", code)
    }

    static let names: [UInt16: String] = [
        0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
        0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo", 0x1006: "GetNumObjects",
        0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
        0x100B: "DeleteObject", 0x100C: "SendObjectInfo", 0x100D: "SendObject",
        0x101B: "GetPartialObject", 0x9801: "GetObjectPropsSupported",
        0x9802: "GetObjectPropDesc", 0x9803: "GetObjectPropValue",
        0x9804: "SetObjectPropValue", 0x9805: "GetObjectPropList",
        0x95C1: "AndroidGetPartialObject64", 0x95C2: "AndroidSendPartialObject",
        0x95C3: "AndroidTruncateObject", 0x95C4: "AndroidBeginEditObject",
        0x95C5: "AndroidEndEditObject"
    ]
}

/// PTP/MTP response codes.
public enum PTPResponseCode {
    public static let undefined: UInt16 = 0x2000
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let invalidTransactionID: UInt16 = 0x2004
    public static let operationNotSupported: UInt16 = 0x2005
    public static let parameterNotSupported: UInt16 = 0x2006
    public static let incompleteTransfer: UInt16 = 0x2007
    public static let invalidStorageID: UInt16 = 0x2008
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let invalidObjectFormatCode: UInt16 = 0x200B
    public static let storeFull: UInt16 = 0x200C
    public static let objectWriteProtected: UInt16 = 0x200D
    public static let storeReadOnly: UInt16 = 0x200E
    public static let accessDenied: UInt16 = 0x200F
    public static let partialDeletion: UInt16 = 0x2012
    public static let storeNotAvailable: UInt16 = 0x2013
    public static let specificationByFormatUnsupported: UInt16 = 0x2014
    public static let noValidObjectInfo: UInt16 = 0x2015
    public static let deviceBusy: UInt16 = 0x2019
    public static let invalidParentObject: UInt16 = 0x201A
    public static let invalidParameter: UInt16 = 0x201D
    public static let sessionAlreadyOpen: UInt16 = 0x201E
    public static let transactionCancelled: UInt16 = 0x201F
    public static let specificationOfDestinationUnsupported: UInt16 = 0x2020
    public static let invalidDataset: UInt16 = 0x2023
    public static let mtpInvalidObjectPropCode: UInt16 = 0xA801
    public static let mtpInvalidObjectPropFormat: UInt16 = 0xA802
    public static let mtpInvalidObjectPropValue: UInt16 = 0xA803
    public static let mtpInvalidDataset: UInt16 = 0xA806
    public static let mtpSpecificationByGroupUnsupported: UInt16 = 0xA807
    public static let mtpSpecificationByDepthUnsupported: UInt16 = 0xA808
    public static let mtpObjectTooLarge: UInt16 = 0xA809
    public static let mtpObjectPropNotSupported: UInt16 = 0xA80A

    public static func name(_ code: UInt16) -> String {
        names[code] ?? String(format: "Response 0x%04X", code)
    }

    static let names: [UInt16: String] = [
        0x2000: "Undefined", 0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen",
        0x2004: "InvalidTransactionID", 0x2005: "OperationNotSupported",
        0x2006: "ParameterNotSupported", 0x2007: "IncompleteTransfer",
        0x2008: "InvalidStorageID", 0x2009: "InvalidObjectHandle",
        0x200A: "DevicePropNotSupported", 0x200B: "InvalidObjectFormatCode",
        0x200C: "StoreFull", 0x200D: "ObjectWriteProtected", 0x200E: "StoreReadOnly",
        0x200F: "AccessDenied", 0x2010: "NoThumbnailPresent", 0x2011: "SelfTestFailed",
        0x2012: "PartialDeletion", 0x2013: "StoreNotAvailable",
        0x2014: "SpecificationByFormatUnsupported", 0x2015: "NoValidObjectInfo",
        0x2016: "InvalidCodeFormat", 0x2017: "UnknownVendorCode",
        0x2018: "CaptureAlreadyTerminated", 0x2019: "DeviceBusy",
        0x201A: "InvalidParentObject", 0x201B: "InvalidDevicePropFormat",
        0x201C: "InvalidDevicePropValue", 0x201D: "InvalidParameter",
        0x201E: "SessionAlreadyOpen", 0x201F: "TransactionCancelled",
        0x2020: "SpecificationOfDestinationUnsupported", 0x2021: "InvalidEnumHandle",
        0x2022: "NoStreamEnabled", 0x2023: "InvalidDataset",
        0xA801: "MTP_InvalidObjectPropCode", 0xA802: "MTP_InvalidObjectPropFormat",
        0xA803: "MTP_InvalidObjectPropValue", 0xA804: "MTP_InvalidObjectReference",
        0xA806: "MTP_InvalidDataset", 0xA807: "MTP_SpecificationByGroupUnsupported",
        0xA808: "MTP_SpecificationByDepthUnsupported", 0xA809: "MTP_ObjectTooLarge",
        0xA80A: "MTP_ObjectPropNotSupported"
    ]
}

/// Object format codes.
public enum PTPObjectFormat {
    public static let undefined: UInt16 = 0x3000
    public static let association: UInt16 = 0x3001
    public static let exifJPEG: UInt16 = 0x3801
}

/// Association types (ObjectInfo.associationType).
public enum PTPAssociationType {
    public static let undefined: UInt16 = 0x0000
    public static let genericFolder: UInt16 = 0x0001
}

/// MTP object property codes.
public enum MTPObjectProperty {
    public static let storageID: UInt16 = 0xDC01
    public static let objectFormat: UInt16 = 0xDC02
    public static let protectionStatus: UInt16 = 0xDC03
    public static let objectSize: UInt16 = 0xDC04
    public static let objectFileName: UInt16 = 0xDC07
    public static let dateCreated: UInt16 = 0xDC08
    public static let dateModified: UInt16 = 0xDC09
    public static let parentObject: UInt16 = 0xDC0B
    public static let persistentUniqueObjectIdentifier: UInt16 = 0xDC41
    public static let name: UInt16 = 0xDC44

    /// GetObjectPropList wildcard: every property.
    public static let all: UInt32 = 0xFFFF_FFFF
}

/// PTP datatype codes (ObjectPropList elements, property descriptors).
public enum PTPDataType {
    public static let undefined: UInt16 = 0x0000
    public static let int8: UInt16 = 0x0001
    public static let uint8: UInt16 = 0x0002
    public static let int16: UInt16 = 0x0003
    public static let uint16: UInt16 = 0x0004
    public static let int32: UInt16 = 0x0005
    public static let uint32: UInt16 = 0x0006
    public static let int64: UInt16 = 0x0007
    public static let uint64: UInt16 = 0x0008
    public static let int128: UInt16 = 0x0009
    public static let uint128: UInt16 = 0x000A
    public static let arrayMask: UInt16 = 0x4000
    public static let string: UInt16 = 0xFFFF

    /// Encoded width of a fixed-size scalar, or nil for UNDEF/STR/unknown.
    public static func scalarSize(_ type: UInt16) -> Int? {
        switch type {
        case int8, uint8: return 1
        case int16, uint16: return 2
        case int32, uint32: return 4
        case int64, uint64: return 8
        case int128, uint128: return 16
        default: return nil
        }
    }
}

/// USB bulk container types.
public enum PTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// Special handle / parameter values.
public enum PTPHandle {
    /// GetObjectHandles parent value meaning "the storage root".
    public static let root: UInt32 = 0xFFFF_FFFF
    /// Storage ID wildcard: all storages.
    public static let allStorages: UInt32 = 0xFFFF_FFFF
}

/// PTP still-image class-specific control requests (USB Still Image Capture
/// Device Definition, §5.2).
public enum PTPClassRequest {
    public static let cancel: UInt8 = 0x64
    public static let getExtendedEventData: UInt8 = 0x65
    public static let deviceReset: UInt8 = 0x66 // never issued by this stack
    public static let getDeviceStatus: UInt8 = 0x67
    /// Cancel request data: this event code, then the transaction ID.
    public static let cancelEventCode: UInt16 = 0x4001
}
