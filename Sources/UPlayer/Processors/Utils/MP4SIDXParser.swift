//
//  MP4SIDXParser.swift
//  UPlayer
//
//  Created by Max Komleu on 3/23/26.
//

import Foundation

public final class MP4SIDXReference: AnyObject {
    let referenceType: UInt8
    let referencedSize: UInt32
    let subsegmentDuration: UInt32
    let startsWithSAP: Bool
    let sapType: UInt8
    let sapDeltaTime: UInt32
    
    init(referenceType: UInt8, referencedSize: UInt32, subsegmentDuration: UInt32, startsWithSAP: Bool, sapType: UInt8, sapDeltaTime: UInt32) {
        self.referenceType = referenceType
        self.referencedSize = referencedSize
        self.subsegmentDuration = subsegmentDuration
        self.startsWithSAP = startsWithSAP
        self.sapType = sapType
        self.sapDeltaTime = sapDeltaTime
    }
}

public final class MP4SIDX: AnyObject {
    let timescale: UInt32
    let earliestPresentationTime: UInt64
    let firstOffset: UInt64
    let references: [MP4SIDXReference]
    
    init(timescale: UInt32, earliestPresentationTime: UInt64, firstOffset: UInt64, references: [MP4SIDXReference]) {
        self.timescale = timescale
        self.earliestPresentationTime = earliestPresentationTime
        self.firstOffset = firstOffset
        self.references = references
    }
}

public final class SIDXDataReader: AnyObject {
    let data: Data
    var offset: Int = 0
    
    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw readerError(1) }
        defer { offset += 1 }
        return data[offset]
    }

    func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw readerError(2) }
        defer { offset += 2 }
        let value = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            $0.load(as: UInt16.self)
        }
        return UInt16(bigEndian: value)
    }

    func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw readerError(3) }
        defer { offset += 4 }
        let value = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        return UInt32(bigEndian: value)
    }

    func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw readerError(4) }
        defer { offset += 8 }
        let value = data.subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            $0.load(as: UInt64.self)
        }
        return UInt64(bigEndian: value)
    }

    func readASCII(_ count: Int) throws -> String {
        guard offset + count <= data.count else { throw readerError(5) }
        let sub = data.subdata(in: offset..<(offset + count))
        offset += count
        return String(data: sub, encoding: .ascii) ?? ""
    }

    private func readerError(_ code: Int) -> NSError {
        NSError(domain: uplayerErrorDomain, code: code, userInfo: [
            NSLocalizedDescriptionKey: "Unexpected end of SIDX data"
        ])
    }
}

public final class RemoteByteRangeLoader: AnyObject {
    static func load(url: URL, range: ClosedRange<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: uplayerErrorDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid HTTP response"
            ])
        }

        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw NSError(domain: uplayerErrorDomain, code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected HTTP status \(http.statusCode)"
            ])
        }

        return data
    }
}

public final class MP4SIDXParser: AnyObject {
    static func parse(data: Data) throws -> MP4SIDX {
        let reader = SIDXDataReader(data: data)

        _ = try reader.readUInt32() // size
        let type = try reader.readASCII(4)
        guard type == "sidx" else {
            throw NSError(domain: uplayerErrorDomain, code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Expected sidx box"
            ])
        }

        let version = try reader.readUInt8()
        _ = try reader.readUInt8()
        _ = try reader.readUInt8()
        _ = try reader.readUInt8()

        _ = try reader.readUInt32() // reference_ID
        let timescale = try reader.readUInt32()

        let earliestPresentationTime: UInt64
        let firstOffset: UInt64

        if version == 0 {
            earliestPresentationTime = UInt64(try reader.readUInt32())
            firstOffset = UInt64(try reader.readUInt32())
        } else {
            earliestPresentationTime = try reader.readUInt64()
            firstOffset = try reader.readUInt64()
        }

        _ = try reader.readUInt16() // reserved
        let referenceCount = try reader.readUInt16()

        var references: [MP4SIDXReference] = []
        references.reserveCapacity(Int(referenceCount))

        for _ in 0..<referenceCount {
            let raw1 = try reader.readUInt32()
            let referenceType = UInt8((raw1 >> 31) & 0x1)
            let referencedSize = raw1 & 0x7FFF_FFFF

            let subsegmentDuration = try reader.readUInt32()

            let raw3 = try reader.readUInt32()
            let startsWithSAP = ((raw3 >> 31) & 0x1) == 1
            let sapType = UInt8((raw3 >> 28) & 0x7)
            let sapDeltaTime = raw3 & 0x0FFF_FFFF

            references.append(
                MP4SIDXReference(
                    referenceType: referenceType,
                    referencedSize: referencedSize,
                    subsegmentDuration: subsegmentDuration,
                    startsWithSAP: startsWithSAP,
                    sapType: sapType,
                    sapDeltaTime: sapDeltaTime
                )
            )
        }

        return MP4SIDX(
            timescale: timescale,
            earliestPresentationTime: earliestPresentationTime,
            firstOffset: firstOffset,
            references: references
        )
    }
}

public final class HLSByteRangeGenerator: AnyObject {
    static func generatePlaylist(
        mediaURL: URL,
        initRange: ClosedRange<Int64>,
        sidxRange: ClosedRange<Int64>,
        sidx: MP4SIDX,
        isLive: Bool
    ) -> String {

        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"

        let maxSegmentDuration = sidx.references
            .filter { $0.referenceType == 0 }
            .map { Double($0.subsegmentDuration) / Double(sidx.timescale) }
            .max() ?? 1

        playlist += "#EXT-X-TARGETDURATION:\(max(1, Int(ceil(maxSegmentDuration))))\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:1\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:\(isLive ? "EVENT" : "VOD")\n"

        let initLength = initRange.upperBound - initRange.lowerBound + 1
        playlist += "#EXT-X-MAP:URI=\"\(mediaURL.absoluteString)\",BYTERANGE=\"\(initLength)@\(initRange.lowerBound)\"\n"

        var currentOffset = sidxRange.upperBound + 1 + Int64(sidx.firstOffset)

        for reference in sidx.references where reference.referenceType == 0 {
            let duration = Double(reference.subsegmentDuration) / Double(sidx.timescale)
            let byteLength = Int64(reference.referencedSize)

            playlist += "#EXTINF:\(String(format: "%.3f", duration)),\n"
            playlist += "#EXT-X-BYTERANGE:\(byteLength)@\(currentOffset)\n"
            playlist += "\(mediaURL.absoluteString)\n"

            currentOffset += byteLength
        }

        if !isLive {
            playlist += "#EXT-X-ENDLIST\n"
        }

        return playlist
    }
}
