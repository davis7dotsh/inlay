export interface paths {
  "/v1/health": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get: operations["getHealth"];
    put?: never;
    post?: never;
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/preferences": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get: operations["getPreferences"];
    put: operations["updatePreferences"];
    post?: never;
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get: operations["listGenerations"];
    put?: never;
    post: operations["createGeneration"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get: operations["getGeneration"];
    put?: never;
    post?: never;
    delete: operations["deleteGeneration"];
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/audio/{kind}": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["appendAudio"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/finish": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["finishGeneration"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/cancel": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["cancelGeneration"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/retry": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["retryGeneration"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/delivery": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["recordDelivery"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/events": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    /** @description A bounded NDJSON stream of complete GenerationRecord values, with the latest record repeated as a two-second heartbeat. Ends after a terminal record. */
    get: operations["generationEvents"];
    put?: never;
    post?: never;
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/generations/{id}/artifacts/{filename}": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get: operations["downloadArtifact"];
    put?: never;
    post?: never;
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/imports/wispr-flow/known": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["knownWisprFlowIDs"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/imports/wispr-flow": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["beginWisprFlowImport"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/imports/wispr-flow/dictionary": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put: operations["archiveWisprFlowDictionary"];
    post?: never;
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/imports/wispr-flow/{id}/artifacts/{filename}": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put: operations["uploadWisprFlowArtifact"];
    post?: never;
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/imports/wispr-flow/{id}/complete": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post: operations["completeWisprFlowImport"];
    delete?: never;
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
  "/v1/imports/wispr-flow/{id}": {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    get?: never;
    put?: never;
    post?: never;
    delete: operations["cancelWisprFlowImport"];
    options?: never;
    head?: never;
    patch?: never;
    trace?: never;
  };
}
export type webhooks = Record<string, never>;
export interface components {
  schemas: {
    /** Format: uuid */
    UUID: string;
    /** @enum {string} */
    GenerationMode: "dictation" | "test" | "file";
    /** @enum {string} */
    GenerationStatus:
      | "receiving"
      | "queued"
      | "transcribing"
      | "proofreading"
      | "completed"
      | "failed"
      | "cancelled";
    /** @enum {string} */
    AudioKind: "inference" | "original";
    /** @enum {string} */
    WisprFlowArtifactName:
      "source.json" | "source.wav" | "opus.json" | "screenshot.png" | "built-in-audio.bin";
    /** @enum {string} */
    WisprFlowImportOutcome: "imported" | "enriched" | "skipped" | "partial";
    /** @enum {string} */
    TextProcessingStatus:
      "disabled" | "unavailable" | "applied" | "unchanged" | "rejected" | "failed" | "skipped";
    /** @enum {string} */
    SpokenListStyle: "numbered" | "bulleted";
    /** @enum {string} */
    DictationBoundary: "none" | "line" | "paragraph";
    DictionaryEntry: {
      id: string;
      term: string;
      /** @default [] */
      aliases?: string[];
      /** @default false */
      isPriority?: boolean;
    };
    DictionaryList: {
      id: string;
      name: string;
      /** @default [] */
      entries?: components["schemas"]["DictionaryEntry"][];
    };
    PersonalDictionary: {
      lists: components["schemas"]["DictionaryList"][];
    };
    DeviceIdentity: {
      id: string;
      name: string;
    };
    ServerPreferences: {
      /** @enum {string} */
      language:
        | "en"
        | "auto"
        | "es"
        | "fr"
        | "de"
        | "it"
        | "pt"
        | "nl"
        | "ja"
        | "zh"
        | "ko"
        | "hi"
        | "ar"
        | "pl"
        | "ru"
        | "uk"
        | "sv";
      /** @description Missing values use the built-in cleanup prompt; maximum UTF-8 size is 4096 bytes. */
      proofreadingPrompt?: string;
      /** @description Maximum UTF-8 size is 16384 bytes. */
      vocabulary: string;
      dictionary: components["schemas"]["PersonalDictionary"];
      textCorrectionEnabled: boolean;
      keepOriginalAudio: boolean;
    };
    PreferencesSnapshot: {
      revision: number;
      preferences: components["schemas"]["ServerPreferences"];
    };
    ModelRuntimeInfo: {
      modelID: string;
      backend: string;
      ready: boolean;
      message?: string;
    };
    ServerHealth: {
      apiVersion: number;
      serverVersion: string;
      isDev: boolean;
      ready: boolean;
      speech: components["schemas"]["ModelRuntimeInfo"];
      proofreading: components["schemas"]["ModelRuntimeInfo"];
      message?: string;
    };
    CreateGenerationRequest: {
      requestID: components["schemas"]["UUID"];
      device: components["schemas"]["DeviceIdentity"];
      mode: components["schemas"]["GenerationMode"];
    };
    AudioStreamFormat: {
      sampleRate: number;
      channels: number;
    };
    AudioChunkReceipt: {
      nextSequence: number;
      /** Format: int64 */
      frameCount: number;
    };
    FinishGenerationRequest: {
      /** Format: int64 */
      inferenceFrames: number;
      /** Format: int64 */
      originalFrames?: number;
      continuationID?: components["schemas"]["UUID"];
    };
    AudioArtifact: {
      filename: string;
      sampleRate: number;
      channels: number;
      /** Format: int64 */
      frameCount: number;
      /** Format: int64 */
      byteCount: number;
      encoding: string;
    };
    ModelProvenance: {
      modelID: string;
      modelSHA256?: string;
      backend: string;
      engineVersion?: string;
      processingSeconds?: number;
    };
    DeliveryReceipt: {
      status: string;
      message?: string;
      /** Format: date-time */
      reportedAt: string;
    };
    ModelHintUsage: {
      includedTerms: string[];
      omittedTerms: string[];
      tokenCount?: number;
      tokenBudget?: number;
    };
    SpokenListContext: {
      style: components["schemas"]["SpokenListStyle"];
      nextNumber: number;
    };
    ListControlSpan: {
      location: number;
      length: number;
    };
    TextRepairSpan: {
      locationUTF16: number;
      lengthUTF16: number;
      text: string;
    };
    VerifiedTextRepair: {
      abandoned: components["schemas"]["TextRepairSpan"];
      cue: components["schemas"]["TextRepairSpan"];
      replacement: components["schemas"]["TextRepairSpan"];
    };
    TextProcessingRecord: {
      dictionaryTerms: string[];
      dictionaryChangedText: boolean;
      inputText: string;
      outputText: string;
      enabled: boolean;
      status: components["schemas"]["TextProcessingStatus"];
      reason?: string;
      modelID?: string;
      modelSHA256?: string;
      engineVersion?: string;
      processingSeconds?: number;
      wallSeconds?: number;
      proposedText?: string;
      verifiedRepairs?: components["schemas"]["VerifiedTextRepair"][];
    };
    DictationContinuation: {
      list?: components["schemas"]["SpokenListContext"];
      preview: string;
      boundary: components["schemas"]["DictationBoundary"];
    };
    WisprFlowArtifactManifest: {
      filename: components["schemas"]["WisprFlowArtifactName"];
      byteCount: number;
      sha256: string;
    };
    WisprFlowImportRequest: {
      sourceID: components["schemas"]["UUID"];
      /** Format: date-time */
      createdAt: string;
      sourceStatus?: string;
      finalText: string;
      rawText: string;
      durationSeconds?: number;
      variantNames: string[];
      artifacts: components["schemas"]["WisprFlowArtifactManifest"][];
      unarchivedArtifacts?: components["schemas"]["WisprFlowArtifactManifest"][];
    };
    WisprFlowImportSession: {
      id: components["schemas"]["UUID"];
    };
    WisprFlowArtifactReceipt: {
      filename: components["schemas"]["WisprFlowArtifactName"];
      byteCount: number;
    };
    WisprFlowKnownIDsRequest: {
      sourceIDs: components["schemas"]["UUID"][];
    };
    WisprFlowKnownIDsResponse: {
      knownSourceIDs: components["schemas"]["UUID"][];
    };
    WisprFlowDictionaryArchiveReceipt: {
      byteCount: number;
      sha256: string;
    };
    ImportedSource: {
      provider: string;
      sourceID: components["schemas"]["UUID"];
      sourceStatus?: string;
      /** Format: date-time */
      importedAt: string;
      variantNames: string[];
      artifactNames: components["schemas"]["WisprFlowArtifactName"][];
      durationSeconds?: number;
      sourceSHA256: string;
      artifactSHA256: {
        [key: string]: string;
      };
      unarchivedArtifactSHA256?: {
        [key: string]: string;
      };
    };
    GenerationRecord: {
      schemaVersion: number;
      id: components["schemas"]["UUID"];
      requestID: components["schemas"]["UUID"];
      device: components["schemas"]["DeviceIdentity"];
      mode: components["schemas"]["GenerationMode"];
      status: components["schemas"]["GenerationStatus"];
      /** Format: date-time */
      createdAt: string;
      /** Format: date-time */
      updatedAt: string;
      settings: components["schemas"]["PreferencesSnapshot"];
      inferenceAudio?: components["schemas"]["AudioArtifact"];
      originalAudio?: components["schemas"]["AudioArtifact"];
      rawText: string;
      finalText: string;
      insertionText: string;
      previewText: string;
      detectedLanguage?: string;
      speech?: components["schemas"]["ModelProvenance"];
      proofreading?: components["schemas"]["ModelProvenance"];
      textProcessing?: components["schemas"]["TextProcessingRecord"];
      recognitionHints?: components["schemas"]["ModelHintUsage"];
      proofreadingHints?: components["schemas"]["ModelHintUsage"];
      formattingRejectionReason?: string;
      consumedListControls?: components["schemas"]["ListControlSpan"][];
      continuation?: components["schemas"]["DictationContinuation"];
      delivery?: components["schemas"]["DeliveryReceipt"];
      error?: string;
      progress?: number;
      importedSource?: components["schemas"]["ImportedSource"];
    };
    GenerationPage: {
      items: components["schemas"]["GenerationRecord"][];
      nextCursor?: string;
    };
    WisprFlowImportResult: {
      outcome: components["schemas"]["WisprFlowImportOutcome"];
      record: components["schemas"]["GenerationRecord"];
      unarchivedArtifactNames: components["schemas"]["WisprFlowArtifactName"][];
    };
    APIErrorResponse: {
      code: string;
      message: string;
    };
  };
  responses: {
    /** @description A request, admission, or server error. */
    APIError: {
      headers: {
        [name: string]: unknown;
      };
      content: {
        "application/json": components["schemas"]["APIErrorResponse"];
      };
    };
  };
  parameters: never;
  requestBodies: never;
  headers: never;
  pathItems: never;
}
export type $defs = Record<string, never>;
export interface operations {
  getHealth: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["ServerHealth"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  getPreferences: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["PreferencesSnapshot"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  updatePreferences: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/json": components["schemas"]["PreferencesSnapshot"];
      };
    };
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["PreferencesSnapshot"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  listGenerations: {
    parameters: {
      query?: {
        limit?: number;
        before?: string;
        source?: "inlay" | "wispr-flow";
      };
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationPage"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  createGeneration: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/json": components["schemas"]["CreateGenerationRequest"];
      };
    };
    responses: {
      /** @description Success */
      201: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationRecord"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  getGeneration: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationRecord"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  deleteGeneration: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      204: {
        headers: {
          [name: string]: unknown;
        };
        content?: never;
      };
      default: components["responses"]["APIError"];
    };
  };
  appendAudio: {
    parameters: {
      query: {
        sequence: number;
        sampleRate: number;
        channels: number;
      };
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
        kind: components["schemas"]["AudioKind"];
      };
      cookie?: never;
    };
    /** @description Raw interleaved little-endian float32 PCM. Chunks must contain whole frames. Repeated sequences must have identical bytes. */
    requestBody: {
      content: {
        "application/octet-stream": string;
      };
    };
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["AudioChunkReceipt"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  finishGeneration: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/json": components["schemas"]["FinishGenerationRequest"];
      };
    };
    responses: {
      /** @description Success */
      202: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationRecord"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  cancelGeneration: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationRecord"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  retryGeneration: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Accepted */
      202: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationRecord"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  recordDelivery: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/json": components["schemas"]["DeliveryReceipt"];
      };
    };
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["GenerationRecord"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  generationEvents: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/x-ndjson": string;
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  downloadArtifact: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
        filename:
          | "inference.wav"
          | "original.wav"
          | "metadata.json"
          | "transcript.txt"
          | "source.json"
          | "source.wav"
          | "opus.json"
          | "screenshot.png"
          | "built-in-audio.bin";
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/octet-stream": string;
          "audio/wav": string;
          "image/png": string;
          "application/json": string;
          "text/plain": string;
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  knownWisprFlowIDs: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/json": components["schemas"]["WisprFlowKnownIDsRequest"];
      };
    };
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["WisprFlowKnownIDsResponse"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  beginWisprFlowImport: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/json": components["schemas"]["WisprFlowImportRequest"];
      };
    };
    responses: {
      /** @description Success */
      201: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["WisprFlowImportSession"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  archiveWisprFlowDictionary: {
    parameters: {
      query?: never;
      header?: never;
      path?: never;
      cookie?: never;
    };
    /** @description Original Wispr Flow dictionary JSON archive. This does not change the active personal dictionary. */
    requestBody: {
      content: {
        "application/json": unknown;
      };
    };
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["WisprFlowDictionaryArchiveReceipt"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  uploadWisprFlowArtifact: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
        filename: components["schemas"]["WisprFlowArtifactName"];
      };
      cookie?: never;
    };
    requestBody: {
      content: {
        "application/octet-stream": string;
        "application/json": string;
        "audio/wav": string;
        "image/png": string;
      };
    };
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["WisprFlowArtifactReceipt"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  completeWisprFlowImport: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      200: {
        headers: {
          [name: string]: unknown;
        };
        content: {
          "application/json": components["schemas"]["WisprFlowImportResult"];
        };
      };
      default: components["responses"]["APIError"];
    };
  };
  cancelWisprFlowImport: {
    parameters: {
      query?: never;
      header?: never;
      path: {
        id: components["schemas"]["UUID"];
      };
      cookie?: never;
    };
    requestBody?: never;
    responses: {
      /** @description Success */
      204: {
        headers: {
          [name: string]: unknown;
        };
        content?: never;
      };
      default: components["responses"]["APIError"];
    };
  };
}
