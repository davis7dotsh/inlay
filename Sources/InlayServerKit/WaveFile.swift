import Foundation

enum WaveFile {
    /// PCM is supplied in little-endian form by the capture client. Assemble a
    /// standard RIFF header without relying on macOS audio frameworks.
    static func write(rawURL: URL, outputURL: URL, sampleRate: Int, channels: Int, float: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: rawURL.path)
        let count = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let bits = float ? 32 : 16
        guard count > 0, count <= Int(UInt32.max) - 36,
              count % (channels * bits / 8) == 0 else {
            throw ServerConfigurationError.invalid("Audio data is empty or not aligned to complete samples.")
        }
        var header = Data("RIFF".utf8)
        append(UInt32(count + 36), to: &header)
        header.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &header)
        append(UInt16(float ? 3 : 1), to: &header)
        append(UInt16(channels), to: &header)
        append(UInt32(sampleRate), to: &header)
        append(UInt32(sampleRate * channels * bits / 8), to: &header)
        append(UInt16(channels * bits / 8), to: &header)
        append(UInt16(bits), to: &header)
        header.append(Data("data".utf8))
        append(UInt32(count), to: &header)
        try header.write(to: outputURL, options: [.atomic])
        let input = try FileHandle(forReadingFrom: rawURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? input.close(); try? output.close() }
        try output.seekToEnd()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
        try output.synchronize()
    }

    private static func append<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var little = number.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
