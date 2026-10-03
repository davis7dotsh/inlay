import type { components } from "./generated/api";

type Schemas = components["schemas"];

export type UUID = Schemas["UUID"];
export type GenerationMode = Schemas["GenerationMode"];
export type GenerationStatus = Schemas["GenerationStatus"];
export type AudioKind = Schemas["AudioKind"];
export type WisprFlowArtifactName = Schemas["WisprFlowArtifactName"];
export type WisprFlowImportOutcome = Schemas["WisprFlowImportOutcome"];
export type TextProcessingStatus = Schemas["TextProcessingStatus"];
export type SpokenListStyle = Schemas["SpokenListStyle"];
export type DictationBoundary = Schemas["DictationBoundary"];

// Archive/request decoding fills the historical defaults represented as optional
// wire properties. Internally every dictionary and preferences value is complete.
export type DictionaryEntry = Required<Schemas["DictionaryEntry"]>;
export type DictionaryList = Omit<Schemas["DictionaryList"], "entries"> & {
  entries: DictionaryEntry[];
};
export type PersonalDictionary = Omit<Schemas["PersonalDictionary"], "lists"> & {
  lists: DictionaryList[];
};
export type ServerPreferences = Omit<
  Schemas["ServerPreferences"],
  "dictionary" | "proofreadingPrompt"
> & {
  dictionary: PersonalDictionary;
  proofreadingPrompt: string;
};
export type PreferencesSnapshot = Omit<Schemas["PreferencesSnapshot"], "preferences"> & {
  preferences: ServerPreferences;
};

export type DeviceIdentity = Schemas["DeviceIdentity"];
export type ModelRuntimeInfo = Schemas["ModelRuntimeInfo"];
export type ServerHealth = Schemas["ServerHealth"];
export type CreateGenerationRequest = Schemas["CreateGenerationRequest"];
export type AudioStreamFormat = Schemas["AudioStreamFormat"];
export type AudioChunkReceipt = Schemas["AudioChunkReceipt"];
export type FinishGenerationRequest = Schemas["FinishGenerationRequest"];
export type AudioArtifact = Schemas["AudioArtifact"];
export type ModelProvenance = Schemas["ModelProvenance"];
export type DeliveryReceipt = Schemas["DeliveryReceipt"];
export type ModelHintUsage = Schemas["ModelHintUsage"];
export type SpokenListContext = Schemas["SpokenListContext"];
export type ListControlSpan = Schemas["ListControlSpan"];
export type TextRepairSpan = Schemas["TextRepairSpan"];
export type VerifiedTextRepair = Schemas["VerifiedTextRepair"];
export type TextProcessingRecord = Schemas["TextProcessingRecord"];
export type DictationContinuation = Schemas["DictationContinuation"];
export type WisprFlowArtifactManifest = Schemas["WisprFlowArtifactManifest"];
export type WisprFlowImportRequest = Schemas["WisprFlowImportRequest"];
export type WisprFlowImportSession = Schemas["WisprFlowImportSession"];
export type WisprFlowArtifactReceipt = Schemas["WisprFlowArtifactReceipt"];
export type WisprFlowKnownIDsRequest = Schemas["WisprFlowKnownIDsRequest"];
export type WisprFlowKnownIDsResponse = Schemas["WisprFlowKnownIDsResponse"];
export type WisprFlowDictionaryArchiveReceipt = Schemas["WisprFlowDictionaryArchiveReceipt"];
export type ImportedSource = Schemas["ImportedSource"];
export type GenerationRecord = Omit<Schemas["GenerationRecord"], "settings"> & {
  settings: PreferencesSnapshot;
};
export type GenerationPage = Omit<Schemas["GenerationPage"], "items"> & {
  items: GenerationRecord[];
};
export type WisprFlowImportResult = Omit<Schemas["WisprFlowImportResult"], "record"> & {
  record: GenerationRecord;
};
export type APIErrorResponse = Schemas["APIErrorResponse"];

export const API_VERSION = 1;
export const DEFAULT_PORT = 8391;
export const MAXIMUM_RECORDING_SECONDS = 180;
export const MAXIMUM_CHUNK_BYTES = 1_048_576;
export const MAXIMUM_ARTIFACT_BYTES = 8_388_608;
export const MAXIMUM_DICTIONARY_BYTES = 8_388_608;
export const InlayAPI = {
  version: API_VERSION,
  defaultPort: DEFAULT_PORT,
  maximumRecordingSeconds: MAXIMUM_RECORDING_SECONDS,
  maximumChunkBytes: MAXIMUM_CHUNK_BYTES,
} as const;

export const isTerminal = (status: GenerationStatus) =>
  status === "completed" || status === "failed" || status === "cancelled";
