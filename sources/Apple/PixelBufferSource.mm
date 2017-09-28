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
#include <VideoCore/sources/Apple/PixelBufferSource.h>
#include <VideoCore/mixers/IVideoMixer.hpp>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <VideoCore/system/pixelBuffer/Apple/PixelBuffer.h>

#include <CoreVideo/CoreVideo.h>

namespace videocore { namespace Apple {
    
    PixelBufferSource::PixelBufferSource(int width, int height, OSType pixelFormat )
    : m_pixelBuffer(nullptr), m_width(width), m_height(height), m_pixelFormat(pixelFormat)
    {
        CVPixelBufferRef pb = nullptr;
        CVReturn ret = kCVReturnSuccess;
        @autoreleasepool {
            NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (NSString*) kCVPixelBufferWidthKey : @(width),
                (NSString*) kCVPixelBufferHeightKey : @(height),
                (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
            
            ret = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, (__bridge CFDictionaryRef)pixelBufferOptions, &pb);
        }
        if(!ret) {
            m_pixelBuffer = pb;
        } else {
            throw std::runtime_error("PixelBuffer creation failed");
        }
    }
    PixelBufferSource::~PixelBufferSource()
    {
        if(m_pixelBuffer) {
            CVPixelBufferRelease((CVPixelBufferRef)m_pixelBuffer);
            m_pixelBuffer = nullptr;
        }
    }
    
    void
    PixelBufferSource::pushPixelBuffer(void *data, size_t size)
    {
        
        auto outp = m_output.lock();
        
        if(outp) {
            CVPixelBufferLockBaseAddress((CVPixelBufferRef)m_pixelBuffer, 0);
            void* loc = CVPixelBufferGetBaseAddress((CVPixelBufferRef)m_pixelBuffer);
            memcpy(loc, data, size);
            CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)m_pixelBuffer, 0);
            
            glm::mat4 mat = glm::mat4(1.f);
            VideoBufferMetadata md(0.);
            md.setData(4, mat, true, shared_from_this());
            auto pixelBuffer = std::make_shared<Apple::PixelBuffer>((CVPixelBufferRef)m_pixelBuffer, false);
            outp->pushBuffer((const uint8_t*)&pixelBuffer, sizeof(pixelBuffer), md);
        }
    }
    void
    PixelBufferSource::setOutput(std::shared_ptr<IOutput> output)
    {
        m_output = output;
    }
    
}
}
