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
#include "MicSource.h"
#include <dlfcn.h>
#include <VideoCore/mixers/IAudioMixer.hpp>
#import <UIKit/UIKit.h>

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)
#define kNoMoreDataErr -2222
#define MAX_AUDIO_FRAMES 2048

struct PassthroughUserData {
    UInt32 mChannels;
    UInt32 mDataSize;
    const void* mData;
    AudioStreamPacketDescription mPacket;
};


static std::weak_ptr<videocore::iOS::MicSource> s_micSource;

namespace videocore { namespace iOS {

    MicSource::MicSource(double sampleRate, int channelCount, std::function<void(AudioUnit&)> excludeAudioUnit)
    : m_sampleRate(sampleRate), m_channelCount(channelCount)
    {
        setupAudioConverter();
        m_buffer = (uint8_t *)malloc(MAX_AUDIO_FRAMES * sizeof(short int));
        m_decodedData = [NSMutableData new];
    }
    
    MicSource::~MicSource() {
        free(m_buffer);
        m_decodedData = nil;
        AudioConverterDispose(m_audioConverter);
    }
    
    void
    MicSource::setupAudioConverter()
    {
        AudioStreamBasicDescription outFormat;
        memset(&outFormat, 0, sizeof(outFormat));
        outFormat.mSampleRate       = 44100;
        outFormat.mFormatID         = kAudioFormatLinearPCM;
        outFormat.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        outFormat.mBytesPerPacket   = 4;
        outFormat.mFramesPerPacket  = 1;
        outFormat.mBytesPerFrame    = 4;
        outFormat.mChannelsPerFrame = 2;
        outFormat.mBitsPerChannel   = 16;
        outFormat.mReserved         = 0;
        
        
        AudioStreamBasicDescription inFormat;
        memset(&inFormat, 0, sizeof(inFormat));
        inFormat.mSampleRate        = 48000;
        inFormat.mFormatID          = kAudioFormatMPEG4AAC;
        inFormat.mFormatFlags       = 0; //kMPEG4Object_AAC_Main
        inFormat.mBytesPerPacket    = 0;
        inFormat.mFramesPerPacket   = 1024;
        inFormat.mBytesPerFrame     = 0;
        inFormat.mChannelsPerFrame  = 2;
        inFormat.mBitsPerChannel    = 0;
        inFormat.mReserved          = 0;
        
        OSStatus status =  AudioConverterNew(&inFormat, &outFormat, &m_audioConverter);
        if (status != 0) {
            printf("setup converter error, status: %i\n", (int)status);
        }
    }
    
    OSStatus
    MicSource::inInputDataProc(AudioConverterRef aAudioConverter,
                               UInt32* aNumDataPackets /* in/out */,
                               AudioBufferList* aData /* in/out */,
                               AudioStreamPacketDescription** aPacketDesc,
                               void* aUserData)
    {
        
        PassthroughUserData* userData = (PassthroughUserData*)aUserData;
        if (!userData->mDataSize) {
            *aNumDataPackets = 0;
            return kNoMoreDataErr;
        }
        
        if (aPacketDesc) {
            userData->mPacket.mStartOffset = 0;
            userData->mPacket.mVariableFramesInPacket = 0;
            userData->mPacket.mDataByteSize = userData->mDataSize;
            *aPacketDesc = &userData->mPacket;
        }
        
        aData->mBuffers[0].mNumberChannels = userData->mChannels;
        aData->mBuffers[0].mDataByteSize = userData->mDataSize;
        aData->mBuffers[0].mData = const_cast<void*>(userData->mData);
        
        // No more data to provide following this run.
        userData->mDataSize = 0;
        
        return noErr;
    }
    
    void
    MicSource::pushAAC(NSData * frame, long timeStamp)
    {
        uint8_t *data = (uint8_t *)[frame bytes];
        
        auto output = m_output.lock();
        if(output) {
            AudioBufferMetadata md ( timeStamp );
            output->pushBuffer(data, frame.length, md);
        }
    }
    
    void
    MicSource::decodeAudioFrame(NSData * frame)
    {
        PassthroughUserData userData = { 1, (UInt32)frame.length, [frame bytes]};
        
        const uint32_t maxDecodedSamples = MAX_AUDIO_FRAMES * 1;
        
        [m_decodedData setLength:0];
        
        do{
            AudioBufferList decBuffer;
            decBuffer.mNumberBuffers = 1;
            decBuffer.mBuffers[0].mNumberChannels = 1;
            decBuffer.mBuffers[0].mDataByteSize = maxDecodedSamples * sizeof(short int);
            decBuffer.mBuffers[0].mData = m_buffer;
            
            UInt32 numFrames = MAX_AUDIO_FRAMES;
            
            AudioStreamPacketDescription outPacketDescription;
            memset(&outPacketDescription, 0, sizeof(AudioStreamPacketDescription));
            outPacketDescription.mDataByteSize = MAX_AUDIO_FRAMES;
            outPacketDescription.mStartOffset = 0;
            outPacketDescription.mVariableFramesInPacket = 0;
            
            OSStatus rv = AudioConverterFillComplexBuffer(m_audioConverter,
                                                          MicSource::inInputDataProc,
                                                          &userData,
                                                          &numFrames /* in/out */,
                                                          &decBuffer,
                                                          &outPacketDescription);
            
            if (rv && rv != kNoMoreDataErr) {
                NSLog(@"Error decoding audio stream: %d", rv);
                break;
            }
            
            if (numFrames) {
                [m_decodedData appendBytes:decBuffer.mBuffers[0].mData length:decBuffer.mBuffers[0].mDataByteSize];
            }
            
            if (rv == kNoMoreDataErr) {
                break;
            }
            
        }while (true);
        
        uint8_t *pData = (uint8_t *)[m_decodedData bytes];
        inputCallback(pData, m_decodedData.length, (int)(m_decodedData.length / 4));
    }
    
    void
    MicSource::inputCallback(uint8_t *data, size_t data_size, int inNumberFrames)
    {
        auto output = m_output.lock();
        if(output) {
            videocore::AudioBufferMetadata md (0.);
            
            md.setData(m_sampleRate,
                       16,
                       m_channelCount,
                       kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                       m_channelCount * 2,
                       inNumberFrames,
                       false,
                       false,
                       shared_from_this());
            
            output->pushBuffer(data, data_size, md);
        }
    }

    void
    MicSource::setOutput(std::shared_ptr<IOutput> output) {
        m_output = output;
        if(m_sampleRate != 48000) {
            auto mixer = std::dynamic_pointer_cast<IAudioMixer>(output);
            mixer->registerSource(shared_from_this());
        }
    }
}
}
