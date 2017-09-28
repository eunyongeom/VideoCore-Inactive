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
#ifndef __videocore__PixelBufferSource__
#define __videocore__PixelBufferSource__

#include <iostream>
#include <VideoCore/sources/ISource.hpp>
#include <VideoCore/transforms/IOutput.hpp>

#ifdef __APPLE__
#   include <MacTypes.h>
#else
#   include <stdint.h>

    typedef uint32_t OSType;

#endif

namespace videocore { namespace Apple {

    class PixelBufferSource : public ISource, public std::enable_shared_from_this<PixelBufferSource>
    {
        
    public:
        
        /*
         *  @param width            The desired width of the pixel buffer
         *  @param height           The desired height of the pixel buffer
         *  @param pixelFormat      The FourCC format of the pixel data.
         */
        PixelBufferSource(int width, int height, OSType pixelFormat );
        ~PixelBufferSource();
        
        void setOutput(std::shared_ptr<IOutput> output);
        
    public:
        
        void pushPixelBuffer(void* data, size_t size);
        
    private:
        std::weak_ptr<IOutput> m_output;
        void*                  m_pixelBuffer;
        int                    m_width;
        int                    m_height;
        OSType                 m_pixelFormat;
        
    };
}
}

#endif /* defined(__videocore__PixelBufferSource__) */
