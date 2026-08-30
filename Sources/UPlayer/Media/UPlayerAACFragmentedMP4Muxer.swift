//
//  UPlayerAACFragmentedMP4Muxer.swift
//  UPlayer
//
//  Created by Max Komleu on 8/29/26.
//

import Foundation

final class UPlayerAACFragmentedMP4Muxer {

    private let trackID: UInt32 = 1

    func makeInitializationSegment(sampleRate: UInt32,
                                   channels: UInt32,
                                   bitrate: UInt32) throws -> Data {

        var result = Data()

        result.append(makeFTYP())

        result.append(makeMOOV(sampleRate: sampleRate,
                               channels: channels,
                               bitrate: bitrate))

        log("""
            [aac muxer] init
            sampleRate=\(sampleRate)
            channels=\(channels)
            bitrate=\(bitrate)
            trackID=\(trackID)
            timescale=\(sampleRate)
            """,
            loggingLevel: .debug)
        
        return result
    }

    func makeMediaSegment(encoded: UPlayerAACEncodedAudio,
                          sequenceNumber: UInt32,
                          baseDecodeTime: UInt64) throws -> Data {

        guard !encoded.packets.isEmpty else {
            throw UPlayerErrorsList
                .aacEncodongFailed7
        }

        let payload = encoded.packets.reduce(into: Data()) { result, packet in
                result.append(packet.data)
        }

        let sizes = encoded.packets.map {
            $0.data.count
        }

        log("""
            [aac muxer] packets
            count=\(sizes.count)
            total=\(sizes.reduce(0, +))
            min=\(sizes.min() ?? 0)
            max=\(sizes.max() ?? 0)
            first=\(Array(sizes.prefix(10)))
            """,
            loggingLevel: .debug)

        if let first = encoded.packets.first?.data,
           first.count >= 2 {

            log(String(format:"[aac muxer] first AAC bytes=%02X %02X", first[first.startIndex], first[first.index(after: first.startIndex)]), loggingLevel: .debug)
        }

        /*
         Build once with zero data offset so we know
         the final moof length.
        */
        let placeholderMoof = makeMOOF(packets: encoded.packets,
                                       sequenceNumber: sequenceNumber,
                                       baseDecodeTime: baseDecodeTime,
                                       dataOffset: 0)

        /*
         trun.data_offset is relative to moof because
         tfhd sets default-base-is-moof.

         Payload begins after:
             moof
             8-byte mdat header
        */
        let dataOffset = Int32(placeholderMoof.count + 8)

        let moof = makeMOOF(packets: encoded.packets,
                            sequenceNumber: sequenceNumber,
                            baseDecodeTime: baseDecodeTime,
                            dataOffset: dataOffset)

        let mdat = box("mdat", payload)

        var result = Data()

        result.append(moof)
        result.append(mdat)

        log("""
            [aac muxer] fragment layout
            moofBytes=\(moof.count)
            mdatHeaderBytes=8
            mdatBytes=\(mdat.count)
            payloadBytes=\(payload.count)
            expectedTotal=\(moof.count + 8 + payload.count)
            actualTotal=\(result.count)
            trunDataOffset=\(dataOffset)
            expectedDataOffset=\(moof.count + 8)
            """,
            loggingLevel: .debug)
        
        assert(Int(dataOffset) == moof.count + 8, "Invalid trun.data_offset")
        assert(result.count == moof.count + mdat.count, "Invalid fMP4 fragment size")
        assert(mdat.count == payload.count + 8, "Invalid mdat size")

        return result
    }
}

private extension UPlayerAACFragmentedMP4Muxer {

    func makeFTYP() -> Data {

        var payload = Data()

        payload.appendASCII("iso6")
        payload.appendBE(UInt32(1))

        payload.appendASCII("iso6")
        payload.appendASCII("mp41")
        payload.appendASCII("dash")

        return box("ftyp", payload)
    }

    func makeMOOV(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        payload.append(makeMVHD())

        payload.append(makeTRAK(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        payload.append(makeMVEX())

        return box("moov", payload)
    }

    func makeMVHD() -> Data {

        var payload = Data()

        // version + flags
        payload.appendBE(UInt32(0))

        // creation/modification
        payload.appendBE(UInt32(0))
        payload.appendBE(UInt32(0))

        // movie timescale
        payload.appendBE(UInt32(1000))

        // fragmented duration = 0
        payload.appendBE(UInt32(0))

        // rate = 1.0
        payload.appendBE(UInt32(0x00010000))

        // volume = 1.0
        payload.appendBE(UInt16(0x0100))

        payload.appendBE(UInt16(0))

        payload.append(Data(repeating: 0, count: 8))

        payload.appendIdentityMatrix()

        payload.append(Data(repeating: 0, count: 24))

        payload.appendBE(UInt32(2))

        return box("mvhd", payload)
    }

    func makeTRAK(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        payload.append(makeTKHD())

        payload.append(makeMDIA(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        return box("trak", payload)
    }

    func makeTKHD() -> Data {

        var payload = Data()

        // version=0 flags=enabled|in_movie|in_preview
        payload.appendBE(UInt32(0x00000007))

        payload.appendBE(UInt32(0))
        payload.appendBE(UInt32(0))

        payload.appendBE(trackID)

        payload.appendBE(UInt32(0))

        // duration
        payload.appendBE(UInt32(0))

        payload.append(Data(repeating: 0, count: 8))

        payload.appendBE(UInt16(0))
        payload.appendBE(UInt16(0))

        // audio volume
        payload.appendBE(UInt16(0x0100))
        payload.appendBE(UInt16(0))

        payload.appendIdentityMatrix()

        // width/height = 0
        payload.appendBE(UInt32(0))
        payload.appendBE(UInt32(0))

        return box("tkhd", payload)
    }

    func makeMDIA(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        payload.append(makeMDHD(sampleRate: sampleRate))

        payload.append(makeHDLR())

        payload.append(makeMINF(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        return box("mdia", payload)
    }

    func makeMDHD(sampleRate: UInt32) -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))

        payload.appendBE(UInt32(0))
        payload.appendBE(UInt32(0))

        payload.appendBE(sampleRate)

        payload.appendBE(UInt32(0))

        /*
         language = "und"
         ISO-639 packed:
         u=21 n=14 d=4
        */
        let language: UInt16 = UInt16((21 << 10) | (14 << 5) | 4)

        payload.appendBE(language)

        payload.appendBE(UInt16(0))

        return box("mdhd", payload)
    }

    func makeHDLR() -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))

        payload.appendBE(UInt32(0))

        payload.appendASCII("soun")

        payload.append(Data(repeating: 0, count: 12))

        payload.append(Data("SoundHandler\u{0}".utf8))

        return box("hdlr", payload)
    }
}

private extension UPlayerAACFragmentedMP4Muxer {

    func makeMINF(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        payload.append(makeSMHD())

        payload.append(makeDINF())

        payload.append(makeSTBL(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        return box("minf", payload)
    }

    func makeSMHD() -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))

        payload.appendBE(UInt16(0))
        payload.appendBE(UInt16(0))

        return box("smhd", payload)
    }

    func makeDINF() -> Data {

        var urlPayload = Data()

        // self-contained URL
        urlPayload.appendBE(UInt32(0x00000001))

        let url = box("url ", urlPayload)

        var drefPayload = Data()

        drefPayload.appendBE(UInt32(0))
        drefPayload.appendBE(UInt32(1))
        drefPayload.append(url)

        let dref = box("dref", drefPayload)

        return box("dinf", dref)
    }

    func makeSTBL(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        payload.append(makeSTSD(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        payload.append(emptyFullBox("stts", trailing: UInt32(0)))

        payload.append(emptyFullBox("stsc", trailing: UInt32(0)))

        payload.append(makeSTSZ())

        payload.append(emptyFullBox("stco", trailing: UInt32(0)))

        return box("stbl", payload)
    }

    func makeSTSD(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))

        payload.appendBE(UInt32(1))

        payload.append(makeMP4A(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        return box("stsd", payload)
    }

    func makeMP4A(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        var payload = Data()

        // reserved
        payload.append(Data(repeating: 0, count: 6))

        // data_reference_index
        payload.appendBE(UInt16(1))

        // version/revision/vendor
        payload.append(Data(repeating: 0, count: 8))

        payload.appendBE(UInt16(channels))

        // sample size
        payload.appendBE(UInt16(16))

        payload.appendBE(UInt16(0))
        payload.appendBE(UInt16(0))

        // 16.16 sample rate
        payload.appendBE(sampleRate << 16)

        payload.append(makeESDS(sampleRate: sampleRate,
                                channels: channels,
                                bitrate: bitrate))

        return box("mp4a", payload)
    }

    func makeSTSZ() -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))

        // sample_size
        payload.appendBE(UInt32(0))

        // sample_count
        payload.appendBE(UInt32(0))

        return box("stsz", payload)
    }
}

private extension UPlayerAACFragmentedMP4Muxer {

    func makeESDS(sampleRate: UInt32,
                  channels: UInt32,
                  bitrate: UInt32) -> Data {

        let asc = audioSpecificConfig(sampleRate: sampleRate,
                                      channels: channels)

        var decoderSpecific = Data()

        decoderSpecific.append(0x05)
        decoderSpecific.append(UInt8(asc.count))
        decoderSpecific.append(asc)

        var decoderConfigBody = Data()

        // objectTypeIndication = MPEG-4 Audio
        decoderConfigBody.append(0x40)

        /*
         streamType = AudioStream (0x05)
         << 2, reserved bit set.
        */
        decoderConfigBody.append(0x15)

        // bufferSizeDB: 24 bits
        decoderConfigBody.append(0x00)
        decoderConfigBody.append(0x18)
        decoderConfigBody.append(0x00)

        decoderConfigBody.appendBE(bitrate)

        decoderConfigBody.appendBE(bitrate)

        decoderConfigBody.append(decoderSpecific)

        var decoderConfig = Data()

        decoderConfig.append(0x04)

        decoderConfig.append(UInt8(decoderConfigBody.count))

        decoderConfig.append(decoderConfigBody)

        var slConfig = Data()

        slConfig.append(0x06)
        slConfig.append(0x01)
        slConfig.append(0x02)

        var esBody = Data()

        esBody.appendBE(UInt16(1))

        // ES flags
        esBody.append(0x00)

        esBody.append(decoderConfig)

        esBody.append(slConfig)

        var descriptor = Data()

        descriptor.append(0x03)

        descriptor.append(UInt8(esBody.count))

        descriptor.append(esBody)

        var payload = Data()

        // FullBox version + flags
        payload.appendBE(UInt32(0))

        payload.append(descriptor)

        return box("esds", payload)
    }

    func audioSpecificConfig(sampleRate: UInt32,
                             channels: UInt32) -> Data {

        let frequencyIndex = aacFrequencyIndex(sampleRate)

        /*
         AudioSpecificConfig:

         audioObjectType = 2 (AAC-LC)
         samplingFrequencyIndex = 4 bits
         channelConfiguration = 4 bits
        */

        let value: UInt16 = UInt16(2 << 11) | UInt16(frequencyIndex << 7) | UInt16(channels << 3)

        return Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    func aacFrequencyIndex(_ sampleRate: UInt32) -> UInt16 {

        switch sampleRate {
        case 96_000:
            return 0
        case 88_200:
            return 1
        case 64_000:
            return 2
        case 48_000:
            return 3
        case 44_100:
            return 4
        case 32_000:
            return 5
        case 24_000:
            return 6
        case 22_050:
            return 7
        case 16_000:
            return 8
        case 12_000:
            return 9
        case 11_025:
            return 10
        case 8_000:
            return 11
        case 7_350:
            return 12
        default:
            return 8
        }
    }
}

private extension UPlayerAACFragmentedMP4Muxer {

    func makeMVEX() -> Data {

        var trexPayload = Data()

        trexPayload.appendBE(UInt32(0))

        trexPayload.appendBE(trackID)

        // default sample description index
        trexPayload.appendBE(UInt32(1))

        // default sample duration
        trexPayload.appendBE(UInt32(1024))

        // default sample size
        trexPayload.appendBE(UInt32(0))

        // default sample flags
        trexPayload.appendBE(UInt32(0))

        let trex = box("trex", trexPayload)

        return box("mvex", trex)
    }

    func makeMOOF(packets: [UPlayerAACPacket],
                  sequenceNumber: UInt32,
                  baseDecodeTime: UInt64,
                  dataOffset: Int32) -> Data {

        var payload = Data()

        payload.append(makeMFHD(sequenceNumber: sequenceNumber))

        payload.append(makeTRAF(packets: packets,
                                baseDecodeTime: baseDecodeTime,
                                dataOffset: dataOffset))

        return box("moof", payload)
    }

    func makeMFHD(sequenceNumber: UInt32) -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))

        payload.appendBE(sequenceNumber)

        return box("mfhd", payload)
    }

    func makeTRAF(packets: [UPlayerAACPacket],
                  baseDecodeTime: UInt64,
                  dataOffset: Int32) -> Data {

        var payload = Data()

        payload.append(makeTFHD())

        payload.append(makeTFDT(baseDecodeTime: baseDecodeTime))

        payload.append(makeTRUN(packets: packets,
                                dataOffset: dataOffset))

        return box("traf", payload)
    }

    func makeTFHD() -> Data {

        var payload = Data()

        /*
         default-base-is-moof
        */
        payload.appendBE(UInt32(0x00020000))

        payload.appendBE(trackID)

        log("""
            [aac muxer] tfhd
            trackID=\(trackID)
            """,
            loggingLevel: .debug)
        
        return box("tfhd", payload)
    }

    func makeTFDT(baseDecodeTime: UInt64) -> Data {

        var payload = Data()

        /*
         version 1 so decode time is UInt64.
        */
        payload.appendBE(UInt32(0x01000000))

        payload.appendBE(baseDecodeTime)

        return box("tfdt", payload)
    }

    func makeTRUN(packets: [UPlayerAACPacket],
                  dataOffset: Int32) -> Data {

        var payload = Data()

        /*
         data-offset-present
         sample-duration-present
         sample-size-present
        */
        payload.appendBE(UInt32(0x00000301))

        payload.appendBE(UInt32(packets.count))

        payload.appendBE(UInt32(bitPattern: dataOffset))

        for packet in packets {
            payload.appendBE(packet.duration)
            payload.appendBE(UInt32(packet.data.count))
        }

        let totalPayload = packets.reduce(0) {
            $0 + $1.data.count
        }

        log("""
            [aac muxer] trun
            sampleCount=\(packets.count)
            dataOffset=\(dataOffset)
            payloadBytes=\(totalPayload)
            """,
            loggingLevel: .debug)
        
        return box("trun", payload)
    }
}

private extension UPlayerAACFragmentedMP4Muxer {

    func box(_ type: String, _ payload: Data) -> Data {

        precondition(type.utf8.count == 4)

        var result = Data()

        result.appendBE(UInt32(payload.count + 8))

        result.appendASCII(type)

        result.append(payload)

        return result
    }

    func emptyFullBox(_ type: String, trailing: UInt32) -> Data {

        var payload = Data()

        payload.appendBE(UInt32(0))
        payload.appendBE(trailing)

        return box(type, payload)
    }
}

private extension Data {

    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt64) {
        appendBE(UInt32((value >> 32) & 0xFFFFFFFF))
        appendBE(UInt32(value & 0xFFFFFFFF))
    }

    mutating func appendIdentityMatrix() {

        appendBE(UInt32(0x00010000))
        appendBE(UInt32(0))
        appendBE(UInt32(0))

        appendBE(UInt32(0))
        appendBE(UInt32(0x00010000))
        appendBE(UInt32(0))

        appendBE(UInt32(0))
        appendBE(UInt32(0))
        appendBE(UInt32(0x40000000))
    }
}
