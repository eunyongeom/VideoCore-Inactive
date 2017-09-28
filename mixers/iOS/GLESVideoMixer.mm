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


#include <VideoCore/mixers/iOS/GLESVideoMixer.h>
#include <VideoCore/sources/iOS/GLESUtil.h>
#include <VideoCore/filters/FilterFactory.h>

#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <OpenGLES/ES3/gl.h>
#import <UIKit/UIKit.h>

#include <CoreVideo/CoreVideo.h>

#include <glm/gtc/matrix_transform.hpp>


@interface GLESObjCCallback : NSObject
{
    videocore::iOS::GLESVideoMixer* _mixer;
}
- (void) setMixer: (videocore::iOS::GLESVideoMixer*) mixer;
@end
@implementation GLESObjCCallback
- (instancetype) init {
    if((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:UIApplicationWillEnterForegroundNotification object:nil];
        
    }
    return self;
}
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
- (void) notification: (NSNotification*) notification {
    if([notification.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        
        _mixer->mixPaused(true);
        
    }
    /*
    else if([notification.name isEqualToString:UIApplicationWillEnterForegroundNotification]) {
        
        _mixer->mixPaused(false);
        
    }
    */
}
- (void) setMixer: (videocore::iOS::GLESVideoMixer*) mixer
{
    _mixer = mixer;
}
@end
namespace videocore { namespace iOS {

    GLESVideoMixer::GLESVideoMixer( int frame_w,
                                   int frame_h,
                                   double frameDuration,
                                   CVPixelBufferPoolRef pool,
                                   std::function<void(void*)> excludeContext )
    : m_bufferDuration(frameDuration),
    m_glesCtx(nullptr),
    m_frameW(frame_w),
    m_frameH(frame_h),
    m_exiting(false),
    m_mixing(false),
    m_pixelBufferPool(pool),
    m_paused(false),
    m_glJobQueue("com.videocore.composite"),
    m_catchingUp(false),
    m_epoch(std::chrono::steady_clock::now())
    {
        m_current_fb = 0;

        this->initPixelBuffer(m_frameW, m_frameH, &m_pixelBuffer[0]);
        this->initPixelBuffer(m_frameW, m_frameH, &m_pixelBuffer[1]);
        
        m_pixelBufferCount[0] = 0;
        m_pixelBufferCount[1] = 0;
        m_currentPixelBufferCount = 0;
        m_previousPixelBufferCount = 0;
        m_relativeTimestamp = 0;
        
        m_videoMixerQueue = dispatch_queue_create("com.videocore.videomixer", 0);
    }
    
    void
    GLESVideoMixer::initPixelBuffer(int width, int height, CVPixelBufferRef* pixelBufferRef)
    {
        NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                              (NSString*) kCVPixelBufferWidthKey : @(width),
                                              (NSString*) kCVPixelBufferHeightKey : @(height),
                                              (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                              (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
        
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (CFDictionaryRef)pixelBufferOptions, pixelBufferRef);
    }
    
    GLESVideoMixer::~GLESVideoMixer()
    {
        m_paused = true;
        m_output.reset();
        m_exiting = true;
        m_mixThreadCond.notify_all();
        NSLog(@"GLESVideoMixer::~GLESVideoMixer()");
        
        CVPixelBufferRelease(m_pixelBuffer[0]);
        CVPixelBufferRelease(m_pixelBuffer[1]);
        
        if(m_mixThread.joinable()) {
            m_mixThread.join();
        }
        m_glJobQueue.mark_exiting();
        m_glJobQueue.enqueue_sync([](){});

        
        [(id)m_callbackSession release];
        
        dispatch_release(m_videoMixerQueue);
    }
    void
    GLESVideoMixer::start() {
        m_mixThread = std::thread([this](){ this->mixThread(); });
    }
    
    void
    GLESVideoMixer::registerSource(std::shared_ptr<ISource> source,
                                   size_t bufferSize)
    {
        const auto hash = std::hash< std::shared_ptr<ISource> > () (source);
        bool registered = false;
        
        for ( auto it : m_sources) {
            auto lsource = it.lock();
            if(lsource) {
                const auto shash = std::hash< std::shared_ptr<ISource> >() (lsource);
                if(shash == hash) {
                    registered = true;
                    break;
                }
            }
        }
        if(!registered)
        {
            m_sources.push_back(source);
        }
    }
    void
    GLESVideoMixer::releaseBuffer(std::weak_ptr<ISource> source)
    {
        NSLog(@"GLESVideoMixer::releaseBuffer");
    }
    void
    GLESVideoMixer::unregisterSource(std::shared_ptr<ISource> source)
    {
        NSLog(@"GLESVideoMixer::unregisterSource");
        releaseBuffer(source);
        
        auto it = m_sources.begin();
        const auto h = std::hash<std::shared_ptr<ISource> >()(source);
        for ( ; it != m_sources.end() ; ++it ) {
            
            const auto shash = hash(*it);
            
            if(h == shash) {
                m_sources.erase(it);
                break;
            }
            
        }

        for ( int i = m_zRange.first ; i <= m_zRange.second ; ++i )
        {
            for ( auto iit = m_layerMap[i].begin() ; iit!= m_layerMap[i].end() ; ++iit) {
                if((*iit) == h) {
                    m_layerMap[i].erase(iit);
                    break;
                }
            }
        }
        
    }
    void
    GLESVideoMixer::pushBuffer(const uint8_t *const data,
                               size_t size,
                               videocore::IMetadata &metadata)
    {
        
    }
    CVPixelBufferRef
    GLESVideoMixer::getPixelBuffer()
    {
        return m_pixelBuffer[0];
    }
    void
    GLESVideoMixer::savePixelBuffer(CVPixelBufferRef pixelBufferRef)
    {
        
        int current_fb = m_current_fb;
        
        CVPixelBufferLockBaseAddress(pixelBufferRef, kCVPixelBufferLock_ReadOnly);
        
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBufferRef);
        size_t srcHeight = CVPixelBufferGetHeight(pixelBufferRef);
        size_t srcWidth = CVPixelBufferGetWidth(pixelBufferRef);
        
        size_t targetHeight = CVPixelBufferGetHeight(m_pixelBuffer[current_fb]);
        size_t targetWidth = CVPixelBufferGetWidth(m_pixelBuffer[current_fb]);
        
        if(srcWidth != targetWidth || srcHeight != targetHeight) {
            CVPixelBufferRelease(m_pixelBuffer[current_fb]);
            this->initPixelBuffer((int)srcWidth, (int)srcHeight, &m_pixelBuffer[current_fb]);
        }
        
        CVPixelBufferLockBaseAddress(m_pixelBuffer[current_fb], kCVPixelBufferLock_ReadOnly);
        
        memcpy(CVPixelBufferGetBaseAddress(m_pixelBuffer[current_fb]),
               CVPixelBufferGetBaseAddress(pixelBufferRef),
               srcHeight * bytesPerRow);
        
        CVPixelBufferUnlockBaseAddress(pixelBufferRef, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(m_pixelBuffer[current_fb], kCVPixelBufferLock_ReadOnly);
        
        m_currentPixelBufferCount++;
        m_pixelBufferCount[current_fb] = m_currentPixelBufferCount;
    }
    
    void
    GLESVideoMixer::pushBuffer(CVPixelBufferRef pixelBufferRef, long timeStamp)
    {
        if(m_paused.load()) {
            return;
        }
        
        int current_fb = m_current_fb;
        
        CVPixelBufferLockBaseAddress(pixelBufferRef, kCVPixelBufferLock_ReadOnly);
        
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBufferRef);
        size_t srcHeight = CVPixelBufferGetHeight(pixelBufferRef);
        size_t srcWidth = CVPixelBufferGetWidth(pixelBufferRef);
        
        size_t targetHeight = CVPixelBufferGetHeight(m_pixelBuffer[current_fb]);
        size_t targetWidth = CVPixelBufferGetWidth(m_pixelBuffer[current_fb]);
        
        if(srcWidth != targetWidth || srcHeight != targetHeight) {
            CVPixelBufferRelease(m_pixelBuffer[current_fb]);
            this->initPixelBuffer((int)srcWidth, (int)srcHeight, &m_pixelBuffer[current_fb]);
        }
        
        CVPixelBufferLockBaseAddress(m_pixelBuffer[current_fb], kCVPixelBufferLock_ReadOnly);
        
        memcpy(CVPixelBufferGetBaseAddress(m_pixelBuffer[current_fb]),
               CVPixelBufferGetBaseAddress(pixelBufferRef),
               srcHeight * bytesPerRow);
        
        CVPixelBufferUnlockBaseAddress(pixelBufferRef, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(m_pixelBuffer[current_fb], kCVPixelBufferLock_ReadOnly);
        
        m_currentPixelBufferCount++;
        m_pixelBufferCount[current_fb] = m_currentPixelBufferCount;
    }
    /*
    void
    GLESVideoMixer::pushBuffer(CVPixelBufferRef pixelBufferRef, long timeStamp)
    {
        if(m_paused.load()) {
            return;
        }
        
        auto lout = this->m_output.lock();
        if(lout) {
            if(pixelBufferRef) {
                if(m_relativeTimestamp == 0) {
                    m_relativeTimestamp = timeStamp;
                }
                
                MetaData<'vide'> md(timeStamp - m_relativeTimestamp);
                //lout->pushBuffer((uint8_t*)this->m_pixelBuffer[m_current_fb], sizeof(this->m_pixelBuffer[m_current_fb]), md);
                lout->pushBuffer((uint8_t*)pixelBufferRef, sizeof(pixelBufferRef), md);
            }
        }
    }
    */
    void
    GLESVideoMixer::setOutput(std::shared_ptr<IOutput> output)
    {
        m_output = output;
    }
    const std::size_t
    GLESVideoMixer::hash(std::weak_ptr<ISource> source) const
    {
        const auto l = source.lock();
        if (l) {
            return std::hash< std::shared_ptr<ISource> >()(l);
        }
        return 0;
    }
    void
    GLESVideoMixer::mixThread()
    {
        const auto us = std::chrono::microseconds(static_cast<long long>(m_bufferDuration * 1000000.));
        const auto us_25 = std::chrono::microseconds(static_cast<long long>(m_bufferDuration * 250000.));
        m_us25 = us_25;
        
        pthread_setname_np("com.videocore.compositeloop");
        
        //int current_fb = 0;
        
        //bool locked[2] = {false};
        
        m_nextMixTime = m_epoch;
        
        while(!m_exiting.load())
        {
            std::unique_lock<std::mutex> l(m_mutex);
            const auto now = std::chrono::steady_clock::now();
            
            if(now >= (m_nextMixTime)) {
                
                auto currentTime = m_nextMixTime;
                if(!m_shouldSync) {
                    m_nextMixTime += us;
                } else {
                    m_nextMixTime = m_syncPoint > m_nextMixTime ? m_syncPoint + us : m_nextMixTime + us;
                }
                
                
                if(m_mixing.load() || m_paused.load()) {
                    continue;
                }
                
                //locked[current_fb] = true;
                
                m_mixing = true;

                dispatch_async(m_videoMixerQueue, ^{

                    auto lout = this->m_output.lock();
                    if(lout) {
                        if(this->m_pixelBuffer[!m_current_fb] &&
                           (this->m_pixelBufferCount[!m_current_fb] > this->m_previousPixelBufferCount)){
                            
                            this->m_previousPixelBufferCount = this->m_pixelBufferCount[!m_current_fb];
                            
                            long ts = (CACurrentMediaTime() * 1000);
                            if(m_relativeTimestamp == 0) {
                                m_relativeTimestamp = ts;
                            }
                            
                            MetaData<'vide'> md(ts - m_relativeTimestamp);
                            lout->pushBuffer((uint8_t*)this->m_pixelBuffer[!m_current_fb], sizeof(this->m_pixelBuffer[!m_current_fb]), md);
                        }
                    }
                    this->m_mixing = false;
        
                });
                m_current_fb = !m_current_fb;
            }
            
            m_mixThreadCond.wait_until(l, m_nextMixTime);
                
        }
    }
    
    void
    GLESVideoMixer::mixPaused(bool paused)
    {
        if(m_paused && !paused) {
            m_relativeTimestamp = 0;
        }
        
        m_paused = paused;
        
        if(paused) {
            m_pixelBufferCount[0] = 0;
            m_pixelBufferCount[1] = 0;
            m_currentPixelBufferCount = 0;
            m_previousPixelBufferCount = 0;
        }
    }
    
    void
    GLESVideoMixer::setSourceFilter(std::weak_ptr<ISource> source, IVideoFilter *filter) {
        auto h = hash(source);
        m_sourceFilters[h] = filter;
    }
    void
    GLESVideoMixer::sync() {
        m_syncPoint = std::chrono::steady_clock::now();
        m_shouldSync = true;
        //if(m_syncPoint >= (m_nextMixTime)) {
        //    m_mixThreadCond.notify_all();
        //}
    }
}
}
