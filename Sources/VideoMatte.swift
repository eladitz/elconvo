// Background removal for video: Vision finds the subject (people or animals) in every frame, and
// the background is made transparent, blurred or green. Sound is carried over.

import AVFoundation
import CoreImage
import Vision

enum VideoBackground: String, CaseIterable {
    case transparent = "Transparent (.mov)"
    case blur = "Blurred background"
    case green = "Green screen"

    var suffix: String {
        switch self {
        case .transparent: "no background"
        case .blur: "blurred background"
        case .green: "green screen"
        }
    }
}

enum VideoMatte {
    static func run(_ url: URL, background: VideoBackground) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConvertError("This file has no video track.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let size = try await videoTrack.load(.naturalSize)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let width = Int(size.width), height = Int(size.height)
        let frames = max(1, Int(duration.seconds * Double(fps > 0 ? fps : 30)))

        let transparent = background == .transparent
        let out = Ops.sibling(url, background.suffix, ext: transparent ? "mov" : "mp4")

        // Reading: frames as BGRA, sound decoded to PCM (so it can go into either container).
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        var audioSettings: [String: Any] = [:]
        if let audioTrack {
            let format = try await audioTrack.load(.formatDescriptions).first
            let source = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channels = min(Int(source?.mChannelsPerFrame ?? 2), 2)
            let rate = min(source?.mSampleRate ?? 44_100, 48_000)
            let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm)
            reader.add(output)
            audioOut = output
            audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels,
                             AVSampleRateKey: rate, AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000]
        }

        // Writing: HEVC with an alpha channel for transparency, H.264 otherwise.
        let writer = try AVAssetWriter(outputURL: out, fileType: transparent ? .mov : .mp4)
        let compression: [String: Any] = transparent
            ? [AVVideoQualityKey: 0.85, "TargetQualityForAlpha": 0.9]
            : [AVVideoAverageBitRateKey: max(2_000_000, Int(Double(width * height) * Double(fps > 0 ? fps : 30) * 0.1))]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: transparent ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression])
        videoIn.transform = try await videoTrack.load(.preferredTransform)   // keep phone videos upright
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw reader.error ?? ConvertError("Couldn't read the video.") }
        guard writer.startWriting() else { throw writer.error ?? ConvertError("Couldn't write the video.") }
        writer.startSession(atSourceTime: .zero)

        let matte = Matte(background: background)
        let report = Converter.report
        let state = PumpState()

        // Picture and sound must be pulled together (one reader feeds both), each on its own queue.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            group.enter()
            videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "elconvo.matte.video")) {
                while videoIn.isReadyForMoreMediaData {
                    guard !state.cancelled, let sample = videoOut.copyNextSampleBuffer(),
                          let frame = CMSampleBufferGetImageBuffer(sample) else {
                        videoIn.markAsFinished()
                        group.leave()
                        return
                    }
                    var buffer: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
                    guard let buffer else {
                        state.cancelled = true
                        continue
                    }
                    matte.render(frame, into: buffer)
                    adaptor.append(buffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample))
                    state.done += 1
                    if state.done % 15 == 0 { report?("frame \(min(state.done, frames)) of \(frames)") }
                }
            }
            if let audioIn, let audioOut {
                group.enter()
                audioIn.requestMediaDataWhenReady(on: DispatchQueue(label: "elconvo.matte.audio")) {
                    while audioIn.isReadyForMoreMediaData {
                        guard let sample = audioOut.copyNextSampleBuffer() else {
                            audioIn.markAsFinished()
                            group.leave()
                            return
                        }
                        audioIn.append(sample)
                    }
                }
            }
            group.notify(queue: .global()) {
                if state.cancelled || reader.status == .failed {
                    writer.cancelWriting()
                    continuation.resume(throwing: reader.error ?? ConvertError("Ran out of memory for video frames."))
                    return
                }
                writer.finishWriting {
                    if let error = writer.error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        return out
    }

    final class PumpState: @unchecked Sendable {
        var done = 0
        var cancelled = false
    }

    /// Per-frame work: find the subject, smooth its outline over time, composite over the new background.
    final class Matte: @unchecked Sendable {
        let background: VideoBackground
        private var previous: CIImage?
        private let context = Converter.ciContext
        private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

        init(background: VideoBackground) { self.background = background }

        func render(_ frame: CVPixelBuffer, into out: CVPixelBuffer) {
            let image = CIImage(cvPixelBuffer: frame)
            let extent = image.extent
            var mask = subjectMask(image) ?? CIImage(color: .black).cropped(to: extent)
            // Blend with the last frame's outline so edges don't shimmer from frame to frame.
            if let previous {
                mask = previous.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: mask, kCIInputTimeKey: 0.8])
            }
            previous = mask

            let backdrop: CIImage
            switch background {
            case .transparent: backdrop = CIImage(color: .clear).cropped(to: extent)
            case .green: backdrop = CIImage(color: CIColor(red: 0, green: 0.85, blue: 0.2)).cropped(to: extent)
            case .blur: backdrop = image.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.width) / 45).cropped(to: extent)
            }
            let result = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: backdrop, kCIInputMaskImageKey: mask])
            context.render(result, to: out, bounds: extent, colorSpace: sRGB)
        }

        /// The subject's mask at full frame size, or nil when there's no clear subject.
        /// Analysed on a smaller copy: segmentation doesn't need 4K, and it's the slow step.
        private func subjectMask(_ image: CIImage) -> CIImage? {
            let extent = image.extent
            let scale = min(1, 768 / max(extent.width, extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
                  let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            else { return nil }
            return CIImage(cvPixelBuffer: buffer)
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(cg.width), y: extent.height / CGFloat(cg.height)))
                .cropped(to: extent)
        }
    }
}
