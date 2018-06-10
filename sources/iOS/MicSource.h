/*

 Video Core
 Copyright (c) 2014 James G. Hurley

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.

 */
#ifndef __videocore__MicSource__
#define __videocore__MicSource__

#include <iostream>
#import <CoreAudio/CoreAudioTypes.h>
#import <AudioToolbox/AudioToolbox.h>
#include <VideoCore/sources/ISource.hpp>
#include <VideoCore/transforms/IOutput.hpp>

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>



namespace videocore { namespace iOS {

    /*!
     *  Capture audio from the device's microphone.
     *
     */

    class MicSource : public ISource, public std::enable_shared_from_this<MicSource>
    {
    public:

        MicSource(double sampleRate = 48000.,
                  int channelCount = 2,
                  std::function<void(AudioUnit&)> excludeAudioUnit = nullptr);

        /*! Destructor */
        ~MicSource();


    public:
        /*! ISource::setOutput */
        void setOutput(std::shared_ptr<IOutput> output);
        void setAacOutput(std::shared_ptr<IOutput> output);
        void decodeAudioFrame(NSData * frame);
        void inputCallback(uint8_t *data, size_t data_size, int inNumberFrames);
        void pushAAC(NSData * frame, long timeStamp);

    private:
        
        void setupAudioConverter();
        static OSStatus inInputDataProc(AudioConverterRef aAudioConverter,
                                        UInt32* aNumDataPackets /* in/out */,
                                        AudioBufferList* aData /* in/out */,
                                        AudioStreamPacketDescription** aPacketDesc,
                                        void* aUserData);

        double m_sampleRate;
        int m_channelCount;

        std::weak_ptr<IOutput> m_output;
        std::weak_ptr<IOutput> m_aacOutput;
        
        AudioConverterRef m_audioConverter;
        uint8_t *m_buffer;
        NSMutableData *m_decodedData;
    };

}
}
@interface InterruptionHandler : NSObject
{
    @public
    videocore::iOS::MicSource* _source;
}
- (void) handleInterruption: (NSNotification*) notification;
@end

#endif /* defined(__videocore__MicSource__) */
