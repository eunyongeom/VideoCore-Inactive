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
#include <VideoCore/transforms/IEncoder.hpp>
#include <VideoCore/system/Buffer.hpp>
#include <deque>

#include <CoreVideo/CoreVideo.h>

namespace videocore { namespace Apple {
 
    class H264Encode : public IEncoder
    {
    public:
        H264Encode( int frame_w, int frame_h, int fps, int bitrate, bool useBaseline = true, int ctsOffset = 0 );
        ~H264Encode();
        
        CVPixelBufferPoolRef pixelBufferPool();
        
    public:
        /*! ITransform */
        void setOutput(std::shared_ptr<IOutput> output) { m_output = output; };
        
        // Input is expecting a CVPixelBufferRef
        void pushBuffer(const uint8_t* const data, size_t size, IMetadata& metadata);
        
    public:
        /*! IEncoder */
        void setBitrate(int bitrate) ;
        
        const int bitrate() const { return m_bitrate; };
        
        void requestKeyframe();
        
    public:
        void compressionSessionOutput(const uint8_t* data, size_t size, uint64_t pts, uint64_t dts);
        
    private:
        void setupCompressionSession( bool useBaseline );
        void teardownCompressionSession();
        
    private:
        
    
        
        std::mutex             m_encodeMutex;
        std::weak_ptr<IOutput> m_output;
        void*                  m_compressionSession;
        int                    m_frameW;
        int                    m_frameH;
        int                    m_fps;
        int                    m_bitrate;
        
        int                    m_ctsOffset;

        bool                   m_baseline;
        bool                   m_forceKeyframe;
    };
}
}