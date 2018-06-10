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

#ifndef __videocore__MP4Multiplexer__
#define __videocore__MP4Multiplexer__

#include <iostream>
#include <vector>
#include <VideoCore/transforms/IOutputSession.hpp>

namespace videocore { namespace Apple {
    
    enum {
        kMP4SessionFPS=0,
        kMP4SessionWidth,
        kMP4SessionHeight
    };
    typedef MetaData<'mp4', int, int, int> MP4SessionParameters_t;
    
    typedef enum {
        kMP4SessionStateNone=0,
        kMP4SessionStateFinishWriting,
        kMP4SessionStateNotEnoughMemory,
        kMP4SessionStateReached4GB
    } MP4SessionState_t;
    
    using MP4SessionStateCallback = std::function<void(MP4SessionState_t state, NSString* fileSize)>;
    
    class MP4Multiplexer : public IOutputSession
    {
        
    public:
        MP4Multiplexer(MP4SessionStateCallback callback);
        ~MP4Multiplexer();
        
        void startWriting(IMetadata & parameters, NSString* iso6709Notation);
        void pauseWriting();
        void finishWriting();
        void setSessionParameters(IMetadata & parameters);
        void setBandwidthCallback(BandwidthCallback callback);
        void pushBuffer(const uint8_t* const data, size_t size, IMetadata& metadata);
        void setEpoch(const std::chrono::steady_clock::time_point epoch) { m_epoch = epoch; };
        
    private:
        void pushVideoBuffer(const uint8_t* const data, size_t size, IMetadata& metadata);
        void pushAudioBuffer(const uint8_t* const data, size_t size, IMetadata& metadata);
        void createAVCC();
        BOOL isMemoryCheckTime();
        uint64_t getFreeDiskspace();
        MP4SessionState_t checkMemorySpace();
        
    private:
        MP4SessionStateCallback m_callback;
        
        std::string m_filepath;
        
        AVAssetWriter* m_assetWriter;
        AVAssetWriterInput* m_videoInput;
        AVAssetWriterInput* m_audioInput;
        
        CMFormatDescriptionRef m_videoFormat;
        CMFormatDescriptionRef m_audioFormat;
        
        std::vector<uint8_t> m_sps;
        std::vector<uint8_t> m_pps;
        
        std::chrono::steady_clock::time_point m_epoch;
        
        int m_fps;
        int m_width;
        int m_height;
        int m_framecount;
        
        double m_ctsOffset;
                
        double videoPtsStart;
        double videoPtsNow;
        double videoPtsPause;
        
        double videoDtsStart;
        double videoDtsNow;
        double videoDtsPause;
        
        double audioTimeStampStart;
        double audioTimeStampNow;
        double audioPausedTimeStamp;
        
        BOOL pauseVideo;
        BOOL pauseAudio;
        
        BOOL isFirstVideoBuffer;
        BOOL isFirstAudioBuffer;
        
        int frameCounter;
        long long m_fileSize;
        
        dispatch_queue_t writerQueue;
    };
    
}
}
#endif /* defined(__videocore__MP4Multiplexer__) */
