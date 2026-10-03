import Foundation
import InlayAPIWire
import InlayDomain

/// Swift-facing models retain their validation and convenience APIs while every
/// transport operation passes through a model generated from the OpenAPI contract.
public protocol APIWireModel: Codable {
    associatedtype Wire: Codable
}

extension InlayAPI {
    public static func decodeWire<Value: APIWireModel>(_ type: Value.Type, from data: Data) throws -> Value {
        // Decode the facade from the original bytes. Re-encoding the generated
        // model would turn explicit nulls into omitted fields and bypass custom
        // dictionary validation or alter historical decoding defaults.
        let value = try decoder().decode(type, from: data)
        _ = try decoder().decode(Value.Wire.self, from: data)
        return value
    }

    public static func encodeWire<Value: APIWireModel>(_ value: Value) throws -> Data {
        let wire = try decoder().decode(Value.Wire.self, from: encoder().encode(value))
        return try encoder().encode(wire)
    }
}

extension DeviceIdentity: APIWireModel { public typealias Wire = Components.Schemas.DeviceIdentity }
extension ServerPreferences: APIWireModel { public typealias Wire = Components.Schemas.ServerPreferences }
extension PreferencesSnapshot: APIWireModel { public typealias Wire = Components.Schemas.PreferencesSnapshot }
extension ModelRuntimeInfo: APIWireModel { public typealias Wire = Components.Schemas.ModelRuntimeInfo }
extension ServerHealth: APIWireModel { public typealias Wire = Components.Schemas.ServerHealth }
extension GenerationMode: APIWireModel { public typealias Wire = Components.Schemas.GenerationMode }
extension GenerationStatus: APIWireModel { public typealias Wire = Components.Schemas.GenerationStatus }
extension AudioKind: APIWireModel { public typealias Wire = Components.Schemas.AudioKind }
extension CreateGenerationRequest: APIWireModel { public typealias Wire = Components.Schemas.CreateGenerationRequest }
extension AudioStreamFormat: APIWireModel { public typealias Wire = Components.Schemas.AudioStreamFormat }
extension AudioChunkReceipt: APIWireModel { public typealias Wire = Components.Schemas.AudioChunkReceipt }
extension FinishGenerationRequest: APIWireModel { public typealias Wire = Components.Schemas.FinishGenerationRequest }
extension AudioArtifact: APIWireModel { public typealias Wire = Components.Schemas.AudioArtifact }
extension ModelProvenance: APIWireModel { public typealias Wire = Components.Schemas.ModelProvenance }
extension DeliveryReceipt: APIWireModel { public typealias Wire = Components.Schemas.DeliveryReceipt }
extension ModelHintUsage: APIWireModel { public typealias Wire = Components.Schemas.ModelHintUsage }
extension WisprFlowArtifactName: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowArtifactName }
extension WisprFlowArtifactManifest: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowArtifactManifest }
extension WisprFlowImportRequest: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowImportRequest }
extension WisprFlowImportSession: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowImportSession }
extension WisprFlowArtifactReceipt: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowArtifactReceipt }
extension WisprFlowImportOutcome: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowImportOutcome }
extension WisprFlowImportResult: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowImportResult }
extension WisprFlowKnownIDsRequest: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowKnownIDsRequest }
extension WisprFlowKnownIDsResponse: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowKnownIDsResponse }
extension WisprFlowDictionaryArchiveReceipt: APIWireModel { public typealias Wire = Components.Schemas.WisprFlowDictionaryArchiveReceipt }
extension ImportedSource: APIWireModel { public typealias Wire = Components.Schemas.ImportedSource }
extension GenerationRecord: APIWireModel { public typealias Wire = Components.Schemas.GenerationRecord }
extension GenerationPage: APIWireModel { public typealias Wire = Components.Schemas.GenerationPage }
extension APIErrorResponse: APIWireModel { public typealias Wire = Components.Schemas.APIErrorResponse }
extension DictionaryEntry: APIWireModel { public typealias Wire = Components.Schemas.DictionaryEntry }
extension DictionaryList: APIWireModel { public typealias Wire = Components.Schemas.DictionaryList }
extension PersonalDictionary: APIWireModel { public typealias Wire = Components.Schemas.PersonalDictionary }
extension SpokenListContext: APIWireModel { public typealias Wire = Components.Schemas.SpokenListContext }
extension ListControlSpan: APIWireModel { public typealias Wire = Components.Schemas.ListControlSpan }
extension DictationContinuation: APIWireModel { public typealias Wire = Components.Schemas.DictationContinuation }
extension TextRepairSpan: APIWireModel { public typealias Wire = Components.Schemas.TextRepairSpan }
extension VerifiedTextRepair: APIWireModel { public typealias Wire = Components.Schemas.VerifiedTextRepair }
extension TextProcessingRecord: APIWireModel { public typealias Wire = Components.Schemas.TextProcessingRecord }
