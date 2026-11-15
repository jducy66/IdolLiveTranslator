import ReplayKit
import AVFoundation
import Network

class SampleHandler: RPBroadcastSampleHandler {
    private var connection: NWConnection?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9999)
        connection = NWConnection(to: endpoint, using: .udp)
        connection?.start(queue: .global(qos: .userInteractive))
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let sourceFormat = AVAudioFormat(streamDescription: asbdPtr)
        guard let srcFormat = sourceFormat else { return }

        if converter == nil || converter?.inputFormat != srcFormat {
            converter = AVAudioConverter(from: srcFormat, to: targetFormat)
        }
        guard let audioConverter = converter else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: pcmBuffer.mutableAudioBufferList
        )

        let ratio = 16000.0 / srcFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(numSamples) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

        var error: NSError?
        var inputProvided = false
        audioConverter.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        if error == nil, outBuffer.frameLength > 0, let channelData = outBuffer.int16ChannelData {
            let byteCount = Int(outBuffer.frameLength) * 2
            let data = Data(bytes: channelData[0], count: byteCount)
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }
}
