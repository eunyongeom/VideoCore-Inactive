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
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoCore/system/DDLog.h>

#include <VideoCore/transforms/Apple/MP4Multiplexer.h>
#include <VideoCore/mixers/IAudioMixer.hpp>

#define NOW CACurrentMediaTime() * 1000

namespace videocore { namespace Apple {
 
    MP4Multiplexer::MP4Multiplexer(MP4SessionStateCallback callback)
    : m_callback(callback)
    {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        m_filepath = [[[paths objectAtIndex:0] stringByAppendingString:@"/output.mp4"] UTF8String];
        
        writerQueue = dispatch_queue_create("AutoSaveUtilWriterQueue", NULL);
        
        m_videoFormat = nil;
        
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
        
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                       &inFormat,
                                       0,
                                       NULL,
                                       0,
                                       NULL,
                                       NULL,
                                       &m_audioFormat);
    }
    
    MP4Multiplexer::~MP4Multiplexer()
    {
        if(m_videoFormat) {
            CFRelease(m_videoFormat);
            m_videoFormat = nil;
            m_sps.clear();
            m_pps.clear();
        }
        
        if(m_audioFormat) {
            CFRelease(m_audioFormat);
            m_audioFormat = nil;
        }
        
        dispatch_release(writerQueue);
    }
    
    void
    MP4Multiplexer::finishWriting()
    {
        dispatch_sync(writerQueue, ^{
            DDLogInfo(@"*#*# finishWriting");
            if(m_videoInput != nil){
                [m_videoInput markAsFinished];
            }
            
            if(m_audioInput != nil){
                [m_audioInput markAsFinished];
            }
            
            if(m_assetWriter != nil) {
                void (^releaseAssetWriter)(void) = ^{
                    m_callback(kMP4SessionStateFinishWriting, nil);
                    m_videoInput = nil;
                    m_audioInput = nil;
                    m_assetWriter = nil;
                };
                [m_assetWriter finishWritingWithCompletionHandler:releaseAssetWriter];
            }
        });
    }
    
    void
    MP4Multiplexer::pauseWriting()
    {
        DDLogInfo(@"*#*# pauseWriting");
        pauseVideo = YES;
        pauseAudio = YES;
    }

    void
    MP4Multiplexer::startWriting(videocore::IMetadata &parameters, NSString* iso6709Notation)
    {
        auto & parms = dynamic_cast<videocore::Apple::MP4SessionParameters_t&>(parameters);
        
        //auto filename = parms.getData<kMP4SessionFilename>()  ;
        m_fps = parms.getData<kMP4SessionFPS>();
        m_width = parms.getData<kMP4SessionWidth>();
        m_height = parms.getData<kMP4SessionHeight>();
        m_ctsOffset = 2000 / m_fps;
        DDLogInfo(@"*#*# startWriting (%d, %d, %d)", m_fps, m_width, m_height);
        
        m_videoInput = nil;
        m_audioInput = nil;
        m_assetWriter = nil;
        
        if(m_videoFormat != nil) {
            CFRelease(m_videoFormat);
            m_videoFormat = nil;
            m_sps.clear();
            m_pps.clear();
        }
        
        videoPtsStart = 0;
        videoPtsNow = 0;
        videoPtsPause = 0;
        
        videoDtsStart = 0;
        videoDtsNow = 0;
        videoDtsPause = 0;
        
        audioTimeStampNow = 0;
        audioTimeStampStart = 0;
        audioPausedTimeStamp = 0;
        
        frameCounter = 0;
        
        isFirstVideoBuffer = YES;
        isFirstAudioBuffer = YES;
        
        pauseVideo = NO;
        pauseAudio = NO;
        
        m_videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil];
        m_audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil];
        
        //m_filepath = [NSString stringWithUTF8String:filename.c_str()];
        
        NSString* filepath = [NSString stringWithUTF8String:m_filepath.c_str()];
        
        NSError *error = nil;
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:filepath]) {
            [[NSFileManager defaultManager] removeItemAtPath:filepath error:&error];
        }
        
        if(error) {
            DDLogInfo(@"*#*# removeFile failed : %@", [error localizedDescription]);
        }
        
        NSURL* fileUrl = [NSURL fileURLWithPath:filepath];
        
        m_assetWriter = [[AVAssetWriter alloc] initWithURL:fileUrl
                                                  fileType:AVFileTypeQuickTimeMovie
                                                     error:&error];
        
        if (error) {
            DDLogInfo(@"*#*# AVAssetWirter initialization failed : %@", [error localizedDescription]);
        }
        
        m_videoInput.expectsMediaDataInRealTime = YES;
        m_audioInput.expectsMediaDataInRealTime = YES;
        
        [m_assetWriter addInput:m_videoInput];
        [m_assetWriter addInput:m_audioInput];
        
        if(iso6709Notation != nil && [iso6709Notation isEqualToString:@""] == NO && [iso6709Notation isEqualToString:@"NA"] == NO){
            NSArray *existingMetadataArray = m_assetWriter.metadata;
            NSMutableArray *newMetadataArray = nil;
            if (existingMetadataArray) {
                newMetadataArray = [existingMetadataArray mutableCopy];
            } else {
                newMetadataArray = [[NSMutableArray alloc] init];
            }
            AVMutableMetadataItem *newLocationMetadataItem = [[AVMutableMetadataItem alloc] init];
            newLocationMetadataItem.identifier = AVMetadataIdentifierQuickTimeMetadataLocationISO6709;
            newLocationMetadataItem.key = AVMetadataQuickTimeMetadataKeyLocationISO6709;
            newLocationMetadataItem.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
            newLocationMetadataItem.dataType = (__bridge NSString *)kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709;
            newLocationMetadataItem.value = iso6709Notation;
            [newMetadataArray addObject:newLocationMetadataItem];
            m_assetWriter.metadata = newMetadataArray;
        }
        
        [m_assetWriter startWriting];
        [m_assetWriter startSessionAtSourceTime:kCMTimeZero];
    }
    
    void
    MP4Multiplexer::setSessionParameters(videocore::IMetadata &parameters)
    {
    }
    
    void
    MP4Multiplexer::setBandwidthCallback(BandwidthCallback callback)
    {
    }
    
    void
    MP4Multiplexer::pushBuffer(const uint8_t *const data, size_t size, videocore::IMetadata &metadata)
    {
        switch(metadata.type()) {
            case 'vide':
                // Process video
                pushVideoBuffer(data, size, metadata);
                break;
            case 'soun':
                // Process audio
                pushAudioBuffer(data, size, metadata);
                break;
            default:
                break;
        }
    }
    
    void
    MP4Multiplexer::pushVideoBuffer(const uint8_t* const data, size_t size, IMetadata& metadata)
    {
        const int nalu_type = data[4] & 0x1F;
        
        //DDLogInfo(@"*#*#* nalu_type: %d, size: %zu", nalu_type, size);
        
        if (nalu_type <= 6) {
            if (m_videoInput == nil || m_videoInput.readyForMoreMediaData == NO || m_videoFormat == nil) {
                DDLogInfo(@"Not ready to write video");
                return;
            }
            
            if (isMemoryCheckTime()) {
                MP4SessionState_t state = checkMemorySpace();
                
                switch(state) {
                    case kMP4SessionStateNotEnoughMemory:
                        DDLogInfo(@"Memory is not enough!");
                        if (m_callback) {
                            finishWriting();
                            NSString *displayFileSize = [NSByteCountFormatter stringFromByteCount:m_fileSize
                                                                                       countStyle:NSByteCountFormatterCountStyleFile];
                            DDLogInfo(@"displayFileSize: %@", displayFileSize);
                            //[_delegate notEnoughMemoryReceived:displayFileSize];
                            m_callback(kMP4SessionStateNotEnoughMemory, displayFileSize);
                        }
                        return;
                    case kMP4SessionStateReached4GB:
                        DDLogInfo(@"Volume of video is reached 4GB!");
                        if (m_callback) {
                            //restartAutoSave = YES;
                            finishWriting();
                            //[_delegate reached4GBReceived];
                            m_callback(kMP4SessionStateReached4GB, nil);
                        }
                        return;
                    default:
                        break;
                }
            }

            dispatch_sync(writerQueue, ^{
                double pts = metadata.pts + m_ctsOffset;
                double dts = metadata.dts;
                
                dts = dts > 0 ? dts : pts - m_ctsOffset;
                
                if(isFirstVideoBuffer) {
                    videoPtsStart = pts;
                    videoDtsStart = dts;
                    isFirstVideoBuffer = NO;
                }
                
                if(pauseVideo) {
                    DDLogInfo(@"*#*# if(pauseVideo) {");
                    videoPtsPause = videoPtsNow + 100;
                    videoDtsPause = videoDtsNow + 100;
                    pauseVideo = NO;
                }
                
                videoPtsNow = pts - videoPtsStart + videoPtsPause;
                videoDtsNow = dts - videoDtsStart + videoDtsPause;
                
                //DDLogInfo(@"pts: %f, dts: %f", videoPtsNow, videoDtsNow);
                
                CMSampleTimingInfo timing;
                timing.duration = CMTimeMake(1, m_fps);
                //CMTimeShow(timing.duration);
                
                timing.presentationTimeStamp = CMTimeMake(videoPtsNow, 1000);
                //CMTimeShow(timing.presentationTimeStamp);
                timing.decodeTimeStamp = CMTimeMake(videoDtsNow, 1000);
                
                CMSampleBufferRef sample;
                CMBlockBufferRef buffer;
                CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                   (void*)data,
                                                   size,
                                                   kCFAllocatorNull,
                                                   NULL,
                                                   0,
                                                   size,
                                                   0,
                                                   &buffer);
                
                OSStatus status = CMSampleBufferCreate(kCFAllocatorDefault,
                                                       buffer,
                                                       true,
                                                       NULL,
                                                       NULL,
                                                       m_videoFormat,
                                                       1,
                                                       1,
                                                       &timing,
                                                       1,
                                                       &size,
                                                       &sample);
                
                if (status != noErr) {
                    DDLogInfo(@"Failed to create video sample buffer");
                    return;
                }

                BOOL bOk = [m_videoInput appendSampleBuffer:sample];
                if (bOk == NO) {
                    NSString * errorDesc = m_assetWriter.error.description;
                    NSString * log = [NSString stringWithFormat:@"[VideoWriter addVideo] - error appending video samples - %@", errorDesc];
                    DDLogInfo(@"%@", log);
                }

                CFRelease(sample);
            });
            
        } else if( nalu_type == 7 && m_sps.size() == 0 ) {
            //m_sps.insert(m_sps.end(), &data[4], &data[size-1]);
            m_sps.resize(size-4);
            memcpy(&m_sps[0], data+4, size-4);
            if(m_pps.size() > 0) {
                createAVCC();
                DDLogInfo(@"*#*# pps createAVCC();");
            }
        } else if( nalu_type == 8 && m_pps.size() == 0 ) {
            //m_pps.insert(m_pps.end(), &data[4], &data[size-1]);
            m_pps.resize(size-4);
            memcpy(&m_pps[0], data+4, size-4);
            if(m_sps.size() > 0) {
                createAVCC();
                DDLogInfo(@"*#*# sps createAVCC();");
            }
        }
    }
    
    void
    MP4Multiplexer::pushAudioBuffer(const uint8_t *const data, size_t size, videocore::IMetadata &metadata)
    {
        if (m_audioInput == nil || m_audioInput.readyForMoreMediaData == NO || m_audioFormat == nil) {
            DDLogInfo(@"Not ready to write audio");
            return;
        }
        
        double timeStamp = NOW;
        dispatch_sync(writerQueue, ^{

            if(isFirstAudioBuffer) {
                audioTimeStampStart = timeStamp;
            }
            
            if(pauseAudio == YES) {
                DDLogInfo(@"*#*# if(pauseAudio) {");
                double duration = (timeStamp - audioTimeStampStart) - audioTimeStampNow - audioPausedTimeStamp;
                pauseAudio = NO;
                DDLogInfo(@"*#*# ========> MP4 session is resumed.");
                DDLogInfo(@"vdu : %f, ts : %f, vtn : %f, vtss : %f, vpts : %f", duration, timeStamp, audioTimeStampNow, audioTimeStampStart, audioPausedTimeStamp);
                audioPausedTimeStamp += duration - 100;
            }
            
            audioTimeStampNow = timeStamp - audioTimeStampStart - audioPausedTimeStamp + (m_ctsOffset);
            
            //DDLogInfo(@"*#*# audioTimeStampNow : %f", audioTimeStampNow);
            
            CMSampleTimingInfo timing;
            timing.duration = CMTimeMake(2560, 120000);
            //CMTimeShow(timing.duration);
            
            timing.presentationTimeStamp = CMTimeMake(audioTimeStampNow, 1000);
            //CMTimeShow(timing.presentationTimeStamp);
            timing.decodeTimeStamp = kCMTimeInvalid;
            
            CMSampleBufferRef sample;
            CMBlockBufferRef buffer;
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                               (void*)data,
                                               size,
                                               kCFAllocatorNull,
                                               NULL,
                                               0,
                                               size,
                                               0,
                                               &buffer);
            
            
            OSStatus status = CMSampleBufferCreate(kCFAllocatorDefault,
                                                   buffer,
                                                   true,
                                                   NULL,
                                                   NULL,
                                                   m_audioFormat,
                                                   1,
                                                   1,
                                                   &timing,
                                                   1,
                                                   &size,
                                                   &sample);
            if (status != noErr) {
                DDLogInfo(@"*#*# Failed to create audio sample buffer");
                return;
            }
            
            if (isFirstAudioBuffer) {
                isFirstAudioBuffer = NO;
                CMTime trimTime = CMTimeMakeWithSeconds(0.1, 1000000000);
                // CMTimeMake(AUDIO_TIME_SCALE*5, AUDIO_TIME_SCALE); //
                CFDictionaryRef dict = CMTimeCopyAsDictionary(trimTime, kCFAllocatorDefault);
                CMSetAttachment(sample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, dict, kCMAttachmentMode_ShouldNotPropagate);
                CFRelease(dict);
            }
            
            BOOL bOk = [m_audioInput appendSampleBuffer:sample];
            if (bOk == NO) {
                NSString * errorDesc = m_assetWriter.error.description;
                NSString * log = [NSString stringWithFormat:@"[AudioWriter addAudio] - error appending audio samples - %@", errorDesc];
                DDLogInfo(@"%@", log);
            }
            
            CFRelease(sample);
        });
    }
    
    MP4SessionState_t
    MP4Multiplexer::checkMemorySpace()
    {
        NSString* filepath = [NSString stringWithUTF8String:m_filepath.c_str()];
        NSURL* fileURL = [NSURL fileURLWithPath:filepath];
        NSNumber *fileSizeValue = nil;
        [fileURL getResourceValue:&fileSizeValue
                           forKey:NSURLFileSizeKey
                            error:nil];
        
        m_fileSize = [fileSizeValue longLongValue];
        long long diskMargin = 300 * 1024 * 1024;    // 300 MB
        
        if (getFreeDiskspace() < m_fileSize + diskMargin) {
            return kMP4SessionStateNotEnoughMemory;
        }
        
        long long fourGB = 4 * 1024 * 1024;
        fourGB *= 1024;
        
        if(m_fileSize > fourGB - diskMargin) {
            return kMP4SessionStateReached4GB;
        }
        return kMP4SessionStateNone;
    }
    
    BOOL
    MP4Multiplexer::isMemoryCheckTime()
    {
        frameCounter++;
        if (frameCounter < 10 * m_fps) { // 10 sec
            return NO;
        }
        frameCounter = 0;
        return YES;
    }
    
    uint64_t
    MP4Multiplexer::getFreeDiskspace()
    {
        uint64_t totalFreeSpace = 0;
        NSError *error = nil;
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[paths lastObject] error: &error];
        
        if (dictionary) {
            NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];
            totalFreeSpace = [freeFileSystemSizeInBytes unsignedLongLongValue];
        } else {
            DDLogInfo(@"Error Obtaining System Memory Info: Domain = %@, Code = %ld", [error domain], (long)[error code]);
        }
        
        return totalFreeSpace;
    }
    
    void
    MP4Multiplexer::createAVCC()
    {
        std::vector<uint8_t> avcc;
        
        put_byte(avcc, 1); // version
        put_byte(avcc, m_sps[1]); // profile
        put_byte(avcc, m_sps[2]); // compat
        put_byte(avcc, m_sps[3]); // level
        put_byte(avcc, 0xff);   // 6 bits reserved + 2 bits nal size length - 1 (11)
        put_byte(avcc, 0xe1);   // 3 bits reserved + 5 bits number of sps (00001)
        put_be16(avcc, m_sps.size());
        put_buff(avcc, &m_sps[0], m_sps.size());
        put_byte(avcc, 1);
        put_be16(avcc, m_pps.size());
        put_buff(avcc, &m_pps[0], m_pps.size());
        
        
        const char *avcC = "avcC";
        const CFStringRef avcCKey = CFStringCreateWithCString(kCFAllocatorDefault,
                                                              avcC,
                                                              kCFStringEncodingUTF8);
        const CFDataRef avcCValue = CFDataCreate(kCFAllocatorDefault,
                                                 &avcc[0],
                                                 avcc.size());
        const void *atomDictKeys[] = { avcCKey };
        const void *atomDictValues[] = { avcCValue };
        CFDictionaryRef atomsDict = CFDictionaryCreate(kCFAllocatorDefault,
                                                       atomDictKeys,
                                                       atomDictValues,
                                                       1,
                                                       nil,
                                                       nil);
        
        const void *extensionDictKeys[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms };
        const void *extensionDictValues[] = { atomsDict };
        CFDictionaryRef extensionDict = CFDictionaryCreate(kCFAllocatorDefault,
                                                           extensionDictKeys,
                                                           extensionDictValues,
                                                           1,
                                                           nil,
                                                           nil);
     
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                       kCMVideoCodecType_H264,
                                       m_width,
                                       m_height,
                                       extensionDict,
                                       &m_videoFormat);
        CFRelease(extensionDict);
        CFRelease(atomsDict);
        
    }
    
}
}
