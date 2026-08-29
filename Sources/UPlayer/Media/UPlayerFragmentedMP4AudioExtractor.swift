//
//  UPlayerFragmentedMP4AudioExtractor.swift
//  UPlayer
//
//  Created by Max Komleu on 8/28/26.
//

import Foundation

struct UPlayerMP4AudioSamples {
    let samples: [Data]
    let duration: TimeInterval?
}

struct UPlayerMP4Box {
    let type: String

    /// Absolute range in the original Data.
    let range: Range<Int>

    /// Absolute payload range in the original Data.
    let payloadRange: Range<Int>
}

private struct UPlayerMP4TFHDInfo {

    let baseDataOffset: UInt64?
    let defaultSampleSize: Int?
    let defaultBaseIsMoof: Bool
}

private struct UPlayerMP4TRUNInfo {

    let sampleSizes: [Int]

    /// Signed offset relative to the applicable base-data-offset.
    let dataOffset: Int32?
}

final class UPlayerFragmentedMP4AudioExtractor {

    func extractSamples(
        initializationData: Data?,
        fragmentData: Data
    ) throws -> UPlayerMP4AudioSamples {

        // initializationData is intentionally not required for the
        // current G711 MPD because codec/sample-rate/channel information
        // is already known and fragment sizing is taken from trun/tfhd.
        _ = initializationData

        let boxes = try parseBoxes(
            fragmentData,
            in: 0 ..< fragmentData.count
        )

        guard let moof = boxes.first(
            where: { $0.type == "moof" }
        ) else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        guard let mdat = boxes.first(
            where: {
                $0.type == "mdat" &&
                $0.range.lowerBound >= moof.range.lowerBound
            }
        ) else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let moofChildren = try parseBoxes(
            fragmentData,
            in: moof.payloadRange
        )

        guard let traf = moofChildren.first(
            where: { $0.type == "traf" }
        ) else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let tfhd = try parseTFHD(
            traf: traf,
            data: fragmentData
        )

        let trun = try parseTRUN(
            traf: traf,
            data: fragmentData,
            defaultSampleSize: tfhd.defaultSampleSize
        )

        guard !trun.sampleSizes.isEmpty else {
            // Do not assume entire mdat == one audio sample.
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let baseDataOffset: Int

        if let explicitBase = tfhd.baseDataOffset {

            guard explicitBase <= UInt64(Int.max) else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            baseDataOffset = Int(explicitBase)

        } else if tfhd.defaultBaseIsMoof {

            baseDataOffset = moof.range.lowerBound

        } else {

            /*
             For the first/single traf, the practical ISO-BMFF base
             is the moof location when no explicit base is supplied.

             This is also the normal layout used by CMAF-style
             fragments.
             */
            baseDataOffset = moof.range.lowerBound
        }

        let sampleDataStart: Int

        if let dataOffset = trun.dataOffset {

            let calculated =
                Int64(baseDataOffset) +
                Int64(dataOffset)

            guard calculated >= 0,
                  calculated <= Int64(Int.max) else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            sampleDataStart = Int(calculated)

        } else {

            // No explicit trun.data_offset.
            // For this media layout, sample payload starts in mdat.
            sampleDataStart = mdat.payloadRange.lowerBound
        }

        let totalSampleBytes = try trun.sampleSizes.reduce(0) {
            partial, size in

            guard size >= 0,
                  partial <= Int.max - size else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            return partial + size
        }

        guard sampleDataStart >= mdat.payloadRange.lowerBound,
              sampleDataStart <= mdat.payloadRange.upperBound,
              sampleDataStart + totalSampleBytes <=
                mdat.payloadRange.upperBound else {

            throw UPlayerErrorsList.aacEncodongFailed8
        }

        var samples: [Data] = []
        samples.reserveCapacity(
            trun.sampleSizes.count
        )

        var offset = sampleDataStart

        for size in trun.sampleSizes {

            guard size > 0,
                  offset + size <= fragmentData.count else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            samples.append(
                fragmentData.subdata(
                    in: offset ..< offset + size
                )
            )

            offset += size
        }

        return UPlayerMP4AudioSamples(
            samples: samples,
            duration: nil
        )
    }
}

private extension UPlayerFragmentedMP4AudioExtractor {

    func parseBoxes(
        _ data: Data,
        in range: Range<Int>
    ) throws -> [UPlayerMP4Box] {

        guard range.lowerBound >= 0,
              range.upperBound <= data.count else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        var result: [UPlayerMP4Box] = []
        var offset = range.lowerBound

        while offset + 8 <= range.upperBound {

            let size32 = readUInt32(
                data,
                offset: offset
            )

            let typeRange =
                offset + 4 ..< offset + 8

            guard let type = String(
                data: data.subdata(in: typeRange),
                encoding: .ascii
            ) else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            var headerSize = 8
            var boxSize: UInt64

            switch size32 {

            case 0:
                boxSize = UInt64(
                    range.upperBound - offset
                )

            case 1:
                guard offset + 16 <= range.upperBound else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                boxSize = readUInt64(
                    data,
                    offset: offset + 8
                )

                headerSize = 16

            default:
                boxSize = UInt64(size32)
            }

            guard boxSize >= UInt64(headerSize),
                  boxSize <= UInt64(Int.max) else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            let end = offset + Int(boxSize)

            guard end <= range.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            result.append(
                UPlayerMP4Box(
                    type: type,
                    range: offset ..< end,
                    payloadRange:
                        offset + headerSize ..< end
                )
            )

            offset = end
        }

        return result
    }

    func readUInt32(
        _ data: Data,
        offset: Int
    ) -> UInt32 {

        precondition(
            offset >= 0 &&
            offset + 4 <= data.count
        )

        return data[
            offset ..< offset + 4
        ]
        .reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    func readUInt64(
        _ data: Data,
        offset: Int
    ) -> UInt64 {

        precondition(
            offset >= 0 &&
            offset + 8 <= data.count
        )

        return data[
            offset ..< offset + 8
        ]
        .reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}

private extension UPlayerFragmentedMP4AudioExtractor {

    func parseTFHD(
        traf: UPlayerMP4Box,
        data: Data
    ) throws -> UPlayerMP4TFHDInfo {

        let children = try parseBoxes(
            data,
            in: traf.payloadRange
        )

        guard let tfhd = children.first(
            where: { $0.type == "tfhd" }
        ) else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        // FullBox:
        // version    1 byte
        // flags      3 bytes
        // track_ID   4 bytes

        guard tfhd.payloadRange.count >= 8 else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let start = tfhd.payloadRange.lowerBound

        let flags =
            UInt32(data[start + 1]) << 16 |
            UInt32(data[start + 2]) << 8 |
            UInt32(data[start + 3])

        var offset = start + 8

        let baseDataOffsetPresent =
            (flags & 0x000001) != 0

        let sampleDescriptionIndexPresent =
            (flags & 0x000002) != 0

        let defaultSampleDurationPresent =
            (flags & 0x000008) != 0

        let defaultSampleSizePresent =
            (flags & 0x000010) != 0

        let defaultSampleFlagsPresent =
            (flags & 0x000020) != 0

        let defaultBaseIsMoof =
            (flags & 0x020000) != 0

        var baseDataOffset: UInt64?
        var defaultSampleSize: Int?

        if baseDataOffsetPresent {

            guard offset + 8 <= tfhd.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            baseDataOffset = readUInt64(
                data,
                offset: offset
            )

            offset += 8
        }

        if sampleDescriptionIndexPresent {
            guard offset + 4 <= tfhd.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            offset += 4
        }

        if defaultSampleDurationPresent {
            guard offset + 4 <= tfhd.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            offset += 4
        }

        if defaultSampleSizePresent {

            guard offset + 4 <= tfhd.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            defaultSampleSize = Int(
                readUInt32(
                    data,
                    offset: offset
                )
            )

            offset += 4
        }

        if defaultSampleFlagsPresent {
            guard offset + 4 <= tfhd.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            offset += 4
        }

        return UPlayerMP4TFHDInfo(
            baseDataOffset: baseDataOffset,
            defaultSampleSize: defaultSampleSize,
            defaultBaseIsMoof: defaultBaseIsMoof
        )
    }
}

private extension UPlayerFragmentedMP4AudioExtractor {

    func parseTRUN(
        traf: UPlayerMP4Box,
        data: Data,
        defaultSampleSize: Int?
    ) throws -> UPlayerMP4TRUNInfo {

        let children = try parseBoxes(
            data,
            in: traf.payloadRange
        )

        guard let trun = children.first(
            where: { $0.type == "trun" }
        ) else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        guard trun.payloadRange.count >= 8 else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        let start = trun.payloadRange.lowerBound

        let flags =
            UInt32(data[start + 1]) << 16 |
            UInt32(data[start + 2]) << 8 |
            UInt32(data[start + 3])

        let sampleCount = Int(
            readUInt32(
                data,
                offset: start + 4
            )
        )

        guard sampleCount > 0 else {
            throw UPlayerErrorsList.aacEncodongFailed8
        }

        var offset = start + 8

        let dataOffsetPresent =
            (flags & 0x000001) != 0

        let firstSampleFlagsPresent =
            (flags & 0x000004) != 0

        let sampleDurationPresent =
            (flags & 0x000100) != 0

        let sampleSizePresent =
            (flags & 0x000200) != 0

        let sampleFlagsPresent =
            (flags & 0x000400) != 0

        let compositionTimePresent =
            (flags & 0x000800) != 0

        var dataOffset: Int32?

        if dataOffsetPresent {

            guard offset + 4 <= trun.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            dataOffset = Int32(
                bitPattern: readUInt32(
                    data,
                    offset: offset
                )
            )

            offset += 4
        }

        if firstSampleFlagsPresent {

            guard offset + 4 <= trun.payloadRange.upperBound else {
                throw UPlayerErrorsList.aacEncodongFailed8
            }

            offset += 4
        }

        var sizes: [Int] = []
        sizes.reserveCapacity(sampleCount)

        for _ in 0 ..< sampleCount {

            if sampleDurationPresent {

                guard offset + 4 <= trun.payloadRange.upperBound else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                offset += 4
            }

            if sampleSizePresent {

                guard offset + 4 <= trun.payloadRange.upperBound else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                let size = Int(
                    readUInt32(
                        data,
                        offset: offset
                    )
                )

                guard size > 0 else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                sizes.append(size)

                offset += 4

            } else {

                /*
                 Fix #2:
                 sample size comes from tfhd.default_sample_size.
                */

                guard let defaultSampleSize,
                      defaultSampleSize > 0 else {

                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                sizes.append(
                    defaultSampleSize
                )
            }

            if sampleFlagsPresent {

                guard offset + 4 <= trun.payloadRange.upperBound else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                offset += 4
            }

            if compositionTimePresent {

                guard offset + 4 <= trun.payloadRange.upperBound else {
                    throw UPlayerErrorsList.aacEncodongFailed8
                }

                offset += 4
            }
        }

        return UPlayerMP4TRUNInfo(
            sampleSizes: sizes,
            dataOffset: dataOffset
        )
    }
}
