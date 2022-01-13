//
//  DeepAREffectsManager.swift
//  
//
//  Created by Illia Khrypunov on 04.01.2022.
//

import AVKit
import AVFoundation
import DeepAR

// MARK: - SampleBufferChannel
protocol SampleBufferChannelDelegate: AnyObject {
    func sampleBufferChannel(sampleBufferChannel: SampleBufferChannel,
                             didReadSampleBuffer sampleBuffer: CMSampleBuffer)
    
    func sampleBufferChannel(sampleBufferChannel: SampleBufferChannel,
                             didReadSampleBuffer sampleBuffer: CMSampleBuffer,
                             andMadeWriteSampleBuffer sampleBufferForWrite: inout CVPixelBuffer)
}

class SampleBufferChannel: NSObject {
    private var completionHandler: (() -> ())?
    private var serializationQueue: DispatchQueue
    private var finished: Bool
    
    private var assetWriterInput: AVAssetWriterInput
    private var assetReaderOutput: AVAssetReaderOutput
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    init(assetReaderOutput localAssetReaderOutput: inout AVAssetReaderOutput,
         assetWriterInput localAssetWriterInput: inout AVAssetWriterInput,
         assetWriterAdaptor: inout AVAssetWriterInputPixelBufferAdaptor?) {
        assetReaderOutput = localAssetReaderOutput
        assetWriterInput = localAssetWriterInput
        
        finished = false
        adaptor = assetWriterAdaptor
        serializationQueue = DispatchQueue(label: "SampleBufferChannel queue")
        super.init()
    }
    
    init(assetReaderOutput localAssetReaderOutput: inout AVAssetReaderOutput,
         assetWriterInput localAssetWriterInput: inout AVAssetWriterInput) {
        assetReaderOutput = localAssetReaderOutput
        assetWriterInput = localAssetWriterInput
        
        finished = false
        serializationQueue = DispatchQueue(label: "SampleBufferChannel queue")
        super.init()
    }
    
    func mediaType() -> AVMediaType {
        return assetReaderOutput.mediaType
    }
    
    func startWithDelegate(delegate: SampleBufferChannelDelegate?, localCompletionHandler: (() -> ())?) {
        completionHandler = localCompletionHandler
        assetWriterInput.requestMediaDataWhenReady(on: serializationQueue) {
            
            if self.finished {
                return
            }
            
            var completedOrFailed = false
            
            while self.assetWriterInput.isReadyForMoreMediaData && !completedOrFailed {
                if let sampleBuffer = self.assetReaderOutput.copyNextSampleBuffer() {
                    var success = false
                    
                    let sampleBufferChannel: ((SampleBufferChannel, _ didReadSampleBuffer: CMSampleBuffer, _ andMadeWriteSampleBuffer: inout CVPixelBuffer) -> Void)? = delegate?.sampleBufferChannel
                    if self.adaptor != nil && sampleBufferChannel != nil {
                        var writerBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, self.adaptor!.pixelBufferPool!,
                                                           &writerBuffer);
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        sampleBufferChannel!(self, sampleBuffer, &writerBuffer!)
                        success = self.adaptor!.append(writerBuffer!, withPresentationTime: presentationTime)
                    } else if let sampleBufferChannel = delegate?.sampleBufferChannel
                                as ((SampleBufferChannel, _ didReadSampleBuffer: CMSampleBuffer)->Void)? {
                        sampleBufferChannel(self, sampleBuffer)
                        success = self.assetWriterInput.append(sampleBuffer)
                    }
                    completedOrFailed = !success
                } else {
                    completedOrFailed = true
                }
            }
            
            if completedOrFailed {
                self.callCompletionHandlerIfNecessary()
            }
        }
    }
    
    private func callCompletionHandlerIfNecessary() {
        let oldFinished = finished
        finished = true
        
        if !oldFinished {
            assetWriterInput.markAsFinished()
            
            let localCompletionHandler = completionHandler
            completionHandler = nil
            
            localCompletionHandler?()
        }
    }
}

// MARK: - DeepAREffectsManager
class DeepAREffectsManager: NSObject {
    // MARK: - Properties
    var completion: ((Error?) -> ())?
    
    private let deepAR: DeepAR!
    
    private var asset: AVAsset!
    private var timeRange: CMTimeRange!
    private var writingSamples: Bool = false
    
    private var serializationQueue: DispatchQueue
    
    private var assetReader: AVAssetReader!
    private var assetWriter: AVAssetWriter!
    private var assetAdaptorWriter: AVAssetWriterInputPixelBufferAdaptor!
    private var audioSampleBufferChannel: SampleBufferChannel!
    private var videoSampleBufferChannel: SampleBufferChannel!
    private var cancelled: Bool = false
    
    private var outputUrl: URL!
    
    private var orientation: CGImagePropertyOrientation = .up
    private var ciContext: CIContext? = nil
    
    // MARK: - Init
    init(inputUrl: URL, outputUrl: URL, deepAR: DeepAR) {
        self.asset = AVAsset(url: inputUrl)
        self.outputUrl = outputUrl
        self.serializationQueue = DispatchQueue(label: "DeepAREffectsManager")
        self.deepAR = deepAR
    }
    
    // MARK: - Start
    func start() {
        cancelled = false
        
        let localAsset = asset
        localAsset?.loadValuesAsynchronously(forKeys: ["tracks", "duration"], completionHandler: { [weak self] in
            guard let self = self else { return }
            self.serializationQueue.async {
                if self.cancelled { return }
                var success = true
                var localError: NSError? = nil
                
                success = localAsset?.statusOfValue(forKey: "tracks", error: &localError) == AVKeyValueStatus.loaded
                if success {
                    success = localAsset?.statusOfValue(forKey: "duration", error: &localError) == AVKeyValueStatus.loaded
                }
                
                if success {
                    self.timeRange = CMTimeRangeMake(start: .zero, duration: localAsset!.duration)
                }
                
                if success {
                    do {
                        try self.setUpReaderAndWriterReturningError()
                        success = true
                    } catch {
                        localError = error as NSError
                        success = false
                    }
                }
                if success {
                    do {
                        try self.startReadingAndWritingReturningError()
                        success = true
                    } catch {
                        localError = error as NSError
                        success = false
                    }
                }
                if !success {
                    self.readingAndWritingDidFinishSuccessfully(success: success, withError: localError)
                }
            }
        })
    }
}

// MARK: - Set up reader and writer
private extension DeepAREffectsManager {
    func setUpReaderAndWriterReturningError() throws {
        let localAsset = asset
        let localOutputURL = outputUrl!
        
        assetReader = try AVAssetReader(asset: localAsset!)
        assetWriter = try AVAssetWriter(outputURL: localOutputURL, fileType: .mov)
        
        var audioTrack: AVAssetTrack? = nil
        let audioTracks = localAsset!.tracks(withMediaType: AVMediaType.audio)
        if audioTracks.count > 0 {
            audioTrack = (audioTracks[0] as AVAssetTrack)
        }
        
        var videoTrack: AVAssetTrack? = nil
        let videoTracks = localAsset!.tracks(withMediaType: AVMediaType.video)
        if videoTracks.count > 0 {
            videoTrack = (videoTracks[0] as AVAssetTrack)
        }
        
        if audioTrack != nil {
            let decompressionAudioSettings: [String: Any] = [
                AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM)
            ]
            var output: AVAssetReaderOutput = AVAssetReaderTrackOutput(track: audioTrack!,
                                                                       outputSettings: decompressionAudioSettings)
            assetReader!.add(output)
            
            var stereoChannelLayout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                                                         mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                                                         mNumberChannelDescriptions: 0,
                                                         mChannelDescriptions: .init())
            let channelLayoutAsData = Data(bytes: &stereoChannelLayout,
                                           count: MemoryLayout.size(ofValue: stereoChannelLayout))
            let compressionAudioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: 128000,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: channelLayoutAsData
            ]
            
            var input = AVAssetWriterInput(mediaType: audioTrack!.mediaType, outputSettings: compressionAudioSettings)
            input.expectsMediaDataInRealTime = true
            assetWriter!.add(input)
            
            audioSampleBufferChannel = SampleBufferChannel(assetReaderOutput: &output,
                                                           assetWriterInput: &input)
        }
        
        if videoTrack != nil {
            let decompressionVideoSettings: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey) : NSNumber(value: UInt32(kCVPixelFormatType_32BGRA)),
                String(kCVPixelBufferIOSurfacePropertiesKey) : [:]
            ]
            var output: AVAssetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack!,
                                                                       outputSettings: decompressionVideoSettings)
            assetReader!.add(output)
            
            var formatDescription: CMFormatDescription? = nil
            let formatDescriptions = videoTrack!.formatDescriptions
            if formatDescriptions.count > 0 {
                formatDescription = (formatDescriptions[0] as! CMFormatDescription)
            }
            
            let preferredTransform = videoTrack!.preferredTransform
            let videoAngleInDegree = rad2deg(atan2(preferredTransform.b, preferredTransform.a))
            
            var trackDimensions: CGSize = .zero
            if formatDescription != nil {
                trackDimensions = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription!,
                                                                                    usePixelAspectRatio: false,
                                                                                    useCleanAperture: false)
            } else {
                trackDimensions = videoTrack!.naturalSize
            }
            
            var h: CGFloat = 0
            switch Int(videoAngleInDegree) {
            case 0:
                orientation = CGImagePropertyOrientation.up
            case 90:
                orientation = CGImagePropertyOrientation.left
                h = trackDimensions.width
                trackDimensions.width = trackDimensions.height
                trackDimensions.height = h
            case 180:
                orientation = CGImagePropertyOrientation.down
            case -90:
                h = trackDimensions.width
                trackDimensions.width = trackDimensions.height
                trackDimensions.height = h
                orientation = CGImagePropertyOrientation.right
            default:
                break
            }
            
            deepAR.setRenderingResolutionWithWidth(Int(trackDimensions.width), height: Int(trackDimensions.height))
            
            var compressionSettings: [String: Any]? = nil
            if formatDescription != nil {
                var cleanAperture: [String: Any]? = nil
                let cleanApertureDescr = CMFormatDescriptionGetExtension(formatDescription!,
                                                                         extensionKey: kCMFormatDescriptionExtension_CleanAperture) as! NSDictionary?
                if let cleanApertureDesc = cleanApertureDescr {
                    cleanAperture = [
                        AVVideoCleanApertureWidthKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureWidth]!,
                        AVVideoCleanApertureHeightKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureHeight]!,
                        AVVideoCleanApertureHorizontalOffsetKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureHorizontalOffset]!,
                        AVVideoCleanApertureVerticalOffsetKey :
                            cleanApertureDesc[kCMFormatDescriptionKey_CleanApertureVerticalOffset]!,
                    ]
                }
                
                var pixelAspectRatio: [String: Any]? = nil
                let pixelAspectRatioDescr = CMFormatDescriptionGetExtension(formatDescription!, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as! NSDictionary?
                if let pixelAspectRatioDesc = pixelAspectRatioDescr {
                    pixelAspectRatio = [
                        AVVideoPixelAspectRatioHorizontalSpacingKey :
                            pixelAspectRatioDesc[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing]!,
                        AVVideoPixelAspectRatioVerticalSpacingKey :
                            pixelAspectRatioDesc[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing]!,
                    ]
                }
                
                if cleanAperture != nil || pixelAspectRatio != nil {
                    var mutableCompressionSettings: [String: Any] = [:]
                    if cleanAperture != nil {
                        mutableCompressionSettings[AVVideoCleanApertureKey] = cleanAperture
                    }
                    if pixelAspectRatio != nil {
                        mutableCompressionSettings[AVVideoPixelAspectRatioKey] = pixelAspectRatio
                    }
                    compressionSettings = mutableCompressionSettings
                }
            }
            
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: trackDimensions.width,
                AVVideoHeightKey: trackDimensions.height,
            ]
            if compressionSettings != nil {
                videoSettings[AVVideoCompressionPropertiesKey] = compressionSettings
            }
            
            var input = AVAssetWriterInput(mediaType: videoTrack!.mediaType, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            
            var attributes: [String : Any] = [:]
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: UInt32(kCVPixelFormatType_32ARGB))
            attributes[kCVPixelBufferWidthKey as String] = trackDimensions.width
            attributes[kCVPixelBufferHeightKey as String] = trackDimensions.height
            
            assetAdaptorWriter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                      sourcePixelBufferAttributes: attributes)
            assetWriter.add(input)
            
            videoSampleBufferChannel = SampleBufferChannel(assetReaderOutput: &output,
                                                           assetWriterInput: &input,
                                                           assetWriterAdaptor: &assetAdaptorWriter)
        }
    }
}

// MARK: - Start reading and writing
private extension DeepAREffectsManager {
    func startReadingAndWritingReturningError() throws {
        if !assetReader!.startReading() {
            throw assetReader!.error!
        }
        
        if !assetWriter!.startWriting() {
            throw assetWriter!.error!
        }
        
        
        let dispatchGroup = DispatchGroup()
        
        assetWriter!.startSession(atSourceTime: timeRange!.start)
        
        if audioSampleBufferChannel != nil {
            var delegate: SampleBufferChannelDelegate? = nil
            if videoSampleBufferChannel == nil {
                delegate = self
            }
            
            dispatchGroup.enter()
            audioSampleBufferChannel?.startWithDelegate(delegate: delegate) {
                dispatchGroup.leave()
            }
        }
        if videoSampleBufferChannel != nil {
            dispatchGroup.enter()
            videoSampleBufferChannel.startWithDelegate(delegate: self) {
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: serializationQueue) { [weak self] in
            guard let self = self else { return }
            var finalSuccess = true
            
            if self.cancelled {
                self.assetReader!.cancelReading()
                self.assetWriter!.cancelWriting()
            } else {
                if self.assetReader.status == .failed {
                    finalSuccess = false
                }
                
                if finalSuccess {
                    self.assetWriter!.finishWriting {
                        let success = (self.assetWriter.status == .completed)
                        self.readingAndWritingDidFinishSuccessfully(success: success,
                                                                    withError: self.assetWriter.error)
                    }
                }
            }
        }
    }
}

// MARK: - Read and write finish successfully
private extension DeepAREffectsManager {
    func readingAndWritingDidFinishSuccessfully(success: Bool, withError error: Error?) {
        DispatchQueue.main.sync { [weak self] in
            guard let self = self else { return }
            if !success {
                self.assetReader.cancelReading()
                self.assetWriter.cancelWriting()
            }
            
            self.assetReader = nil
            self.assetWriter = nil
            self.audioSampleBufferChannel = nil
            self.videoSampleBufferChannel = nil
            self.cancelled = false
            
            self.completion?(error)
        }
    }
}

// MARK: - SampleBufferChannelDelegate
extension DeepAREffectsManager: SampleBufferChannelDelegate {
    func sampleBufferChannel(sampleBufferChannel: SampleBufferChannel,
                             didReadSampleBuffer sampleBuffer: CMSampleBuffer) {
        var pixelBuffer: CVPixelBuffer? = nil
        
        let progress = progressOfSampleBufferInTimeRange(sampleBuffer: sampleBuffer, self.timeRange)
        print("Progress: \(progress)")
        
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        if (imageBuffer != nil) && (CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID()) {
            pixelBuffer = imageBuffer!
            self.deepAR.processFrameAndReturn(pixelBuffer, outputBuffer: pixelBuffer, mirror: false)
        }
    }
    
    func sampleBufferChannel(sampleBufferChannel: SampleBufferChannel,
                             didReadSampleBuffer sampleBuffer: CMSampleBuffer,
                             andMadeWriteSampleBuffer sampleBufferForWrite: inout CVPixelBuffer) {
        let progress = progressOfSampleBufferInTimeRange(sampleBuffer: sampleBuffer, self.timeRange)
        print("Progress: \(progress)")
        
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        if (imageBuffer != nil) && (CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID()) {
            var outputPixelBuffer = imageBuffer!
            rotatePixelBuffer(&outputPixelBuffer)
            self.deepAR.processFrameAndReturn(outputPixelBuffer, outputBuffer: outputPixelBuffer, mirror: false)
        }
    }
}

// MARK: - Helpers
private extension DeepAREffectsManager {
    func rad2deg(_ number: CGFloat) -> CGFloat {
        return number * 180 / .pi
    }
    
    func progressOfSampleBufferInTimeRange(sampleBuffer: CMSampleBuffer!, _ timeRange: CMTimeRange) -> Double {
        var progressTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        progressTime = CMTimeSubtract(progressTime, timeRange.start);
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
        if sampleDuration.isNumeric {
            progressTime = CMTimeAdd(progressTime, sampleDuration)
        }
        return CMTimeGetSeconds(progressTime) / CMTimeGetSeconds(timeRange.duration)
    }
    
    func rotatePixelBuffer(_ pixelBuffer: inout CVPixelBuffer) {
        var width = CVPixelBufferGetWidth(pixelBuffer)
        var height = CVPixelBufferGetHeight(pixelBuffer)
        var cgOrientation: CGImagePropertyOrientation = .up
        switch orientation {
        case .up:
            cgOrientation = .up
            
        case .right:
            cgOrientation = .left
            width = CVPixelBufferGetHeight(pixelBuffer)
            height = CVPixelBufferGetWidth(pixelBuffer)
            
        case .left:
            cgOrientation = .right
            width = CVPixelBufferGetHeight(pixelBuffer)
            height = CVPixelBufferGetWidth(pixelBuffer)
            
        default: break
        }
        
        if (orientation == .up) {
            return
        }
        
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer, options: [.applyOrientationProperty: cgOrientation])
            var newPixelBuffer: CVPixelBuffer? = nil
            CVPixelBufferCreate(kCFAllocatorSystemDefault, width, height, kCVPixelFormatType_32BGRA, nil, &newPixelBuffer)
            if ciContext == nil {
                ciContext = CIContext()
            }
            ciContext?.render(ciImage, to: newPixelBuffer!)
            pixelBuffer = newPixelBuffer!
        }
    }
}
