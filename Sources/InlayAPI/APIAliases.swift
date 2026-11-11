import InlayAPIWire

// Facade retired for types whose generated wire shape is already the client
// shape (plain fields, no custom decode/validation/defaults). Deferred with
// reasons: ServerPreferences/PreferencesSnapshot (custom decode + defaults),
// StorageUsage/PurgeAudioResult/AudioChunkReceipt (Int64 fields vs wire Int),
// DeliveryReceipt (reportedAt default), PurgeAudioRequest (facade AudioKind),
// GenerationRecord/GenerationSummary/GenerationPage (facade status/mode enums
// and UUID fields), WisprFlow* requests (UUID vs wire String), ServerHealth /
// ModelRuntimeInfo (nested facade enums). Revisit if the facade enums retire.
public typealias DeviceIdentity = Components.Schemas.DeviceIdentity
public typealias DeviceSummary = Components.Schemas.DeviceSummary
public typealias DeviceList = Components.Schemas.DeviceList
public typealias EnrollDeviceRequest = Components.Schemas.EnrollDeviceRequest
public typealias EnrollDeviceResponse = Components.Schemas.EnrollDeviceResponse
public typealias APIErrorResponse = Components.Schemas.APIErrorResponse
public typealias ModelProvenance = Components.Schemas.ModelProvenance
public typealias ModelHintUsage = Components.Schemas.ModelHintUsage
