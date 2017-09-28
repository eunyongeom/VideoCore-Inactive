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

#import <VideoCore/api/iOS/VCSimpleSession.h>
//#import <VideoCore/api/iOS/VCPreviewView.h>
#import <VideoCore/system/DDLog.h>
#import <Accelerate/Accelerate.h>

#include <VideoCore/rtmp/RTMPSession.h>
#include <VideoCore/transforms/RTMP/AACPacketizer.h>
#include <VideoCore/transforms/RTMP/H264Packetizer.h>
#include <VideoCore/transforms/Split.h>

#include <VideoCore/mixers/Apple/AudioMixer.h>
#include <VideoCore/transforms/Apple/H264Encode.h>
#include <VideoCore/sources/Apple/PixelBufferSource.h>

#include <VideoCore/sources/iOS/CameraSource.h>
#include <VideoCore/sources/iOS/MicSource.h>
#include <VideoCore/mixers/iOS/GLESVideoMixer.h>
#include <VideoCore/transforms/iOS/AACEncode.h>
#include <VideoCore/transforms/iOS/H264Encode.h>


#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)


#include <sstream>

static const int kMinVideoBitrate = 32000;

@interface VCSimpleSession()
{

    //VCPreviewView* _previewView;

    std::shared_ptr<videocore::iOS::MicSource>               m_micSource;
    std::shared_ptr<videocore::iOS::CameraSource>            m_cameraSource;
    
    std::shared_ptr<videocore::Split> m_videoSplit;

    std::shared_ptr<videocore::IAudioMixer> m_audioMixer;
    std::shared_ptr<videocore::IVideoMixer> m_videoMixer;
    std::shared_ptr<videocore::ITransform>  m_h264Encoder;
    std::shared_ptr<videocore::ITransform>  m_aacEncoder;
    std::shared_ptr<videocore::ITransform>  m_h264Packetizer;
    std::shared_ptr<videocore::ITransform>  m_aacPacketizer;

    std::shared_ptr<videocore::Split>       m_aacSplit;
    std::shared_ptr<videocore::Split>       m_h264Split;

    std::shared_ptr<videocore::IOutputSession> m_outputSession;


    // properties

    dispatch_queue_t _graphManagementQueue;

    CGSize _videoSize;
    int    _bitrate;

    int    _fps;
    int    _bpsCeiling;
    int    _estimatedThroughput;

    BOOL   _useInterfaceOrientation;
    int    _audioChannelCount;
    float  _audioSampleRate;
    float  _micGain;

    VCSessionState _rtmpSessionState;

    BOOL _useAdaptiveBitrate;
    
    BOOL _blockVideoSource;
    
    BOOL _isStartedRtmpSession;
    BOOL _isResumedRtmpSessionInternal;
    BOOL _resumeRtmpSession;
    
    BOOL _isCalledkClientStateSessionStarted;
    BOOL _tryToResumeFromOutside;
    
    BOOL _endRtmpSession;
    BOOL _stopRtmpSession;
    
    int _resumeRtmpSessionCount;
    int _unstableNetworkCount;
    int _saveVideoSourceCount;
    
   	UIImage* _capturedImage;
    
    std::string _rtmpUrl;
    
    NSTimer* _startSessionTimer;
}
@property (nonatomic, readwrite) VCSessionState rtmpSessionState;

- (void) setupGraph;

@end

@implementation VCSimpleSession
@dynamic videoSize;
@dynamic bitrate;
@dynamic fps;
@dynamic useInterfaceOrientation;
@dynamic rtmpSessionState;
@dynamic audioChannelCount;
@dynamic audioSampleRate;
@dynamic micGain;
@dynamic useAdaptiveBitrate;
@dynamic estimatedThroughput;

//@dynamic previewView;
// -----------------------------------------------------------------------------
//  Properties Methods
// -----------------------------------------------------------------------------
#pragma mark - Properties
- (CGSize) videoSize
{
    return _videoSize;
}
- (void) setVideoSize:(CGSize)videoSize
{
    _videoSize = videoSize;
}

- (int) bitrate
{
    return _bitrate;
}

- (void) setBitrate:(int)bitrate
{
    _bitrate = bitrate;
}

- (int) fps
{
    return _fps;
}

- (void) setFps:(int)fps
{
    _fps = fps;
}

- (BOOL) useInterfaceOrientation
{
    return _useInterfaceOrientation;
}

- (void) setRtmpSessionState:(VCSessionState)rtmpSessionState
{
    __block VCSimpleSession* bSelf = self;
    _rtmpSessionState = rtmpSessionState;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        if([bSelf isEndState]) {
            CVPixelBufferRef pixelBuffer = m_videoMixer->getPixelBuffer();
            _capturedImage = [self getUIImageFromCVPixelBuffer:pixelBuffer];
            if(_capturedImage == nil) {
                DDLogInfo(@"Video capture failed.");
            }
        } else {
            _capturedImage = nil;
        }
        
        if (bSelf.delegate && self.rtmpSessionState != VCSessionStateNone) {
            [bSelf.delegate connectionStatusChanged:rtmpSessionState capturedImage:_capturedImage];
        }
    });
}

- (VCSessionState) rtmpSessionState
{
    return _rtmpSessionState;
}

- (void) setAudioChannelCount:(int)channelCount
{
    _audioChannelCount = MAX(1, MIN(channelCount, 2));

    if(m_audioMixer) {
        m_audioMixer->setChannelCount(_audioChannelCount);
    }
}

- (int) audioChannelCount
{
    return _audioChannelCount;
}

- (void) setAudioSampleRate:(float)sampleRate
{

    _audioSampleRate = (sampleRate > 46000 ? 48000 : 44100); // We can only support 48000 / 44100 with AAC + RTMP
    if(m_audioMixer) {
        m_audioMixer->setFrequencyInHz(sampleRate);
    }
}

- (float) audioSampleRate
{
    return _audioSampleRate;
}

- (void) setMicGain:(float)micGain
{
    if(m_audioMixer) {
        m_audioMixer->setSourceGain(m_micSource, micGain);
        _micGain = micGain;
    }
}

- (float) micGain
{
    return _micGain;
}

//- (UIView*) previewView {
//    return _previewView;
//}

- (BOOL) useAdaptiveBitrate {
    return _useAdaptiveBitrate;
}

- (void) setUseAdaptiveBitrate:(BOOL)useAdaptiveBitrate {
    _useAdaptiveBitrate = useAdaptiveBitrate;
    _bpsCeiling = _bitrate;
}

- (int) estimatedThroughput {
    return _estimatedThroughput;
}

// -----------------------------------------------------------------------------
//  Public Methods
// -----------------------------------------------------------------------------
#pragma mark - Public Methods
// -----------------------------------------------------------------------------
+ (instancetype) sharedInstance
{
    static VCSimpleSession *sharedInstance = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[VCSimpleSession alloc] initWithVideoSize:CGSizeMake(1440, 720)
                                                          frameRate:15
                                                            bitrate:4000000
                                            useInterfaceOrientation:NO];
    });
    
    return sharedInstance;
}

- (instancetype) initWithVideoSize:(CGSize)videoSize
                         frameRate:(int)fps
                           bitrate:(int)bps
           useInterfaceOrientation:(BOOL)useInterfaceOrientation
{
    if (( self = [super init] ))
    {
        [self initInternalWithVideoSize:videoSize
                              frameRate:fps
                                bitrate:bps
                useInterfaceOrientation:useInterfaceOrientation];
    }
    return self;
}

- (void) initInternalWithVideoSize:(CGSize)videoSize
                         frameRate:(int)fps
                           bitrate:(int)bps
           useInterfaceOrientation:(BOOL)useInterfaceOrientation
{
    self.bitrate = bps;
    self.videoSize = videoSize;
    self.fps = fps;
    _useInterfaceOrientation = useInterfaceOrientation;
    self.micGain = 1.f;
    self.audioChannelCount = 2;
    self.audioSampleRate = 44100.;
    self.useAdaptiveBitrate = YES;

    //_previewView = [[VCPreviewView alloc] init];

    _graphManagementQueue = dispatch_queue_create("com.videocore.session.graph", 0);
    
    _blockVideoSource = YES;

    _isStartedRtmpSession = NO;
    _isResumedRtmpSessionInternal = NO;
    
    _resumeRtmpSession = NO;
    _resumeRtmpSessionCount = 0;
    
    _unstableNetworkCount = 0;
    
    _isCalledkClientStateSessionStarted = NO;
    _tryToResumeFromOutside = NO;
    
    _endRtmpSession = NO;
    _stopRtmpSession = NO;
    
    _saveVideoSourceCount = 0;

    __block VCSimpleSession* bSelf = self;
    
    m_outputSession = nil;
    
    _capturedImage = nil;
    _startSessionTimer = nil;

    dispatch_async(_graphManagementQueue, ^{
        [bSelf setupGraph];
    });
}

- (void) pushAudioBuffer:(NSData *)frame timeStamp:(long)timeStamp
{
    if(m_micSource) {
        if(self.audioSampleRate != 48000) {
            m_micSource->decodeAudioFrame(frame);
        } else {
            m_micSource->pushAAC(frame, timeStamp);
        }
    }
}

- (void) pushVideoBuffer:(CVPixelBufferRef)pixelBufferRef width:(int)width height:(int)height timeStamp:(long)timeStamp
{
    if(self.rtmpSessionState != VCSessionStateStarted) {
        [self saveVideoSource:pixelBufferRef];
    }
    
    if(_blockVideoSource)
        return;
    
    if(self.videoSize.width != width || self.videoSize.height != height) {
        _videoSize = CGSizeMake(width, height);
        self.videoSize = _videoSize;
    }
    
    //VCPreviewView* preview = (VCPreviewView*)self.previewView;
    //[preview drawFrame:pixelBufferRef isEmptyPixelBuffer:NO];
    
    m_videoMixer->pushBuffer(pixelBufferRef, timeStamp);
    
    if(_resumeRtmpSession && _resumeRtmpSessionCount > 0) {
        _resumeRtmpSessionCount--;
    }
    
    if(_resumeRtmpSessionCount == 0 && _resumeRtmpSession && m_outputSession == nil) {
        
        _resumeRtmpSession = NO;
        
        if(_isResumedRtmpSessionInternal == NO &&
           _isStartedRtmpSession == YES &&
           [self isEndState] == NO) {
           
            DDLogInfo(@"resumeRtmpSessionInternal");
            
            _isResumedRtmpSessionInternal = YES;
            
            __block VCSimpleSession* bSelf = self;
            
            NSString* rtmpUrl = [NSString stringWithUTF8String:_rtmpUrl.c_str()];
            
            dispatch_async(_graphManagementQueue, ^{
                [bSelf startSessionInternal:rtmpUrl];
            });
        }
    }
}

- (void) startPreview
{
    DDLogInfo(@"startPreview");
    _blockVideoSource = NO;
    
    //[_previewView startPreview];
    
    _resumeRtmpSession = YES;
    _resumeRtmpSessionCount = 150;
}

- (void) stopPreview
{
    DDLogInfo(@"stopPreview");
    [self invalidateStartSessionTimer];
    
    if(m_videoMixer)
        m_videoMixer->mixPaused(true);
    
    _blockVideoSource = YES;
    //[_previewView stopPreview];
    _resumeRtmpSession = NO;
    _resumeRtmpSessionCount = 150;
    if(_isStartedRtmpSession && [self isEndState] == NO) {
        [self endRtmpSession];
        _isResumedRtmpSessionInternal = NO;
    }
}

- (void) prepareForRotationPreview
{
    //[_previewView prepareForRotationPreview];
}

- (void) completionRotationPreview
{
    //[_previewView completionRotationPreview];
}

- (void) startRtmpSessionWithURL:(NSString *)rtmpUrl
{
    if(_isStartedRtmpSession || rtmpUrl == nil) {
        return;
    }
    
    DDLogInfo(@"startRtmpSessionWithURL : %@", rtmpUrl);
    
    _isStartedRtmpSession = YES;
    
    __block VCSimpleSession* bSelf = self;
    
    _rtmpUrl = [[NSString stringWithFormat:@"%@", rtmpUrl] UTF8String];

    dispatch_async(_graphManagementQueue, ^{
        [bSelf startSessionInternal:rtmpUrl];
    });
}

- (void) resumeRtmpSessionWithURL:(NSString *)rtmpUrl
{
    if(_isStartedRtmpSession || rtmpUrl == nil) {
        return;
    }
    DDLogInfo(@"resumeRtmpSession : %@", rtmpUrl);

    _isStartedRtmpSession = YES;
    _tryToResumeFromOutside = YES;
    
    __block VCSimpleSession* bSelf = self;
    
    _rtmpUrl = [[NSString stringWithFormat:@"%@", rtmpUrl] UTF8String];
    
    dispatch_async(_graphManagementQueue, ^{
        [bSelf startSessionInternal:rtmpUrl];
    });
}

- (void) endRtmpSessionAndCaptureImage
{
    DDLogInfo(@"endRtmpSessionAndCaptureImage");
    
    _endRtmpSession = YES;
    _blockVideoSource = YES;
    
    [self stopRtmpSession:VCSessionStateEnded];
}

// -----------------------------------------------------------------------------
//  Private Methods
// -----------------------------------------------------------------------------
#pragma mark - Private Methods

- (void) startSessionInternalTimedOut
{
    if(self.rtmpSessionState == VCSessionStateNone || self.rtmpSessionState == VCSessionStateStarting) {
        DDLogInfo(@">>>>> startSessionInternal timed out");
        [self stopRtmpSession:VCSessionStateDisconnected];
    }
}

- (void) invalidateStartSessionTimer
{
    if(_startSessionTimer != nil) {
        DDLogInfo(@">>>>> invalidateStartSessionTimer");
        [_startSessionTimer invalidate];
        _startSessionTimer = nil;
    }
}

- (void) startSessionInternal: (NSString*) rtmpUrl
{
    if(rtmpUrl == nil) {
        return;
    }
    
    DDLogInfo(@"startSessionInternal : %@", rtmpUrl);
    
    self.rtmpSessionState = VCSessionStateNone;
    
    _startSessionTimer = [NSTimer scheduledTimerWithTimeInterval:10
                                                          target:self
                                                        selector:@selector(startSessionInternalTimedOut)
                                                        userInfo:nil
                                                         repeats:NO];

    _unstableNetworkCount = 0;
    _capturedImage = nil;
    _endRtmpSession = NO;
    _stopRtmpSession = NO;
    
    std::stringstream uri ;
    uri << (rtmpUrl ? [rtmpUrl UTF8String] : "");
    
    m_outputSession.reset(
                          new videocore::RTMPSession ( uri.str(),
                                                      [=](videocore::RTMPSession& session,
                                                          ClientState_t state) {
                                                          
                                                          DDLogInfo(@"ClientState: %d", state);
                                                          
                                                          switch(state) {
                                                                  
                                                              case kClientStateConnected:
                                                                  DDLogInfo(@"kClientStateConnected");
                                                                  if(_isResumedRtmpSessionInternal == NO || _isCalledkClientStateSessionStarted == NO) {
                                                                      _blockVideoSource = NO;
                                                                      if(_tryToResumeFromOutside == NO) {
                                                                          DDLogInfo(@"VCSessionStateStarting");
                                                                          self.rtmpSessionState = VCSessionStateStarting;
                                                                      }
                                                                  }
                                                                  break;
                                                              case kClientStateSessionStarted:
                                                              {
                                                                  DDLogInfo(@"kClientStateSessionStarted");
                                                                  [self invalidateStartSessionTimer];
                                                                  __block VCSimpleSession* bSelf = self;
                                                                  dispatch_async(_graphManagementQueue, ^{
                                                                      [bSelf addEncodersAndPacketizers];
                                                                  });
                                                              }
                                                                  if(_tryToResumeFromOutside) {
                                                                      _tryToResumeFromOutside = NO;
                                                                      _isCalledkClientStateSessionStarted = YES;
                                                                      DDLogInfo(@"VCSessionStateResumed");
                                                                      self.rtmpSessionState = VCSessionStateResumed;
                                                                  } else if(_isResumedRtmpSessionInternal == NO || _isCalledkClientStateSessionStarted == NO) {
                                                                      _isCalledkClientStateSessionStarted = YES;
                                                                      DDLogInfo(@"VCSessionStateStarted");
                                                                      self.rtmpSessionState = VCSessionStateStarted;
                                                                  }
                                                                  break;
                                                              case kClientStateError:
                                                                  DDLogInfo(@"kClientStateError");
                                                                  [self stopRtmpSession:VCSessionStateError];
                                                                  break;
                                                              case kClientStateNotConnected:
                                                                  DDLogInfo(@"kClientStateNotConnected");
                                                                  [self stopRtmpSession:VCSessionStateDisconnected];
                                                                  break;
                                                              default:
                                                                  break;
                                                          }
                                                          
                                                      }) );
    VCSimpleSession* bSelf = self;

    _bpsCeiling = _bitrate;

    if ( self.useAdaptiveBitrate ) {
        _bitrate = 500000;
    }

    m_outputSession->setBandwidthCallback([=](float vector, float predicted, int inst)
                                          {

                                              bSelf->_estimatedThroughput = predicted;
                                              auto video = std::dynamic_pointer_cast<videocore::IEncoder>( bSelf->m_h264Encoder );
                                              //auto audio = std::dynamic_pointer_cast<videocore::IEncoder>( bSelf->m_aacEncoder );
                                              if(video && bSelf.useAdaptiveBitrate) {

                                                  if ([bSelf.delegate respondsToSelector:@selector(detectedThroughput:)]) {
                                                      [bSelf.delegate detectedThroughput:predicted];
                                                  }
                                                  if ([bSelf.delegate respondsToSelector:@selector(detectedThroughput:videoRate:)]) {
                                                      [bSelf.delegate detectedThroughput:predicted videoRate:video->bitrate()];
                                                  }


                                                  int videoBr = 0;

                                                  if(vector != 0) {

                                                      vector = vector < 0 ? -1 : 1 ;

                                                      videoBr = video->bitrate();
                                                      
                                                      if(videoBr < 160000) {
                                                          if(_unstableNetworkCount < 8) {
                                                              DDLogInfo(@"WeakSignal %d", _unstableNetworkCount);
                                                              if((_unstableNetworkCount % 2) == 0) {
                                                                  if ([bSelf.delegate respondsToSelector:@selector(weakSignalDetected)]) {
                                                                      dispatch_async(dispatch_get_main_queue(), ^{
                                                                          [bSelf.delegate weakSignalDetected];
                                                                      });
                                                                  }
                                                              }
                                                          } else {
                                                              DDLogInfo(@"VCSessionStateUnstableNetwork %d", _unstableNetworkCount);
                                                              [self stopRtmpSession:VCSessionStateUnstableNetwork];
                                                          }
                                                          _unstableNetworkCount++;
                                                      } else {
                                                          _unstableNetworkCount = 0;
                                                      }

//                                                      if (audio) {
//
//                                                          if ( videoBr > 500000 ) {
//                                                              audio->setBitrate(128000);
//                                                          } else if (videoBr <= 500000 && videoBr > 250000) {
//                                                              audio->setBitrate(96000);
//                                                          } else {
//                                                              audio->setBitrate(80000);
//                                                          }
//                                                      }


                                                      if(videoBr > 1152000) {
                                                          video->setBitrate(std::min(int((videoBr / 384000 + vector )) * 384000, bSelf->_bpsCeiling) );
                                                      }
                                                      else if( videoBr > 512000 ) {
                                                          video->setBitrate(std::min(int((videoBr / 128000 + vector )) * 128000, bSelf->_bpsCeiling) );
                                                      }
                                                      else if( videoBr > 128000 ) {
                                                          video->setBitrate(std::min(int((videoBr / 64000 + vector )) * 64000, bSelf->_bpsCeiling) );
                                                      }
                                                      else {
                                                          video->setBitrate(std::max(std::min(int((videoBr / 32000 + vector )) * 32000, bSelf->_bpsCeiling), kMinVideoBitrate) );
                                                      }
                                                      DDLogInfo(@"(%f) VideoBR: %d (%f)", vector, video->bitrate(), predicted);
                                                  } /* if(vector != 0) */

                                              } /* if(video && audio && m_adaptiveBREnabled) */

                                          });

    videocore::RTMPSessionParameters_t sp ( 0. );

    sp.setData(self.videoSize.width,
               self.videoSize.height,
               1. / static_cast<double>(self.fps),
               self.bitrate,
               self.audioSampleRate,
               (self.audioChannelCount == 2));

    m_outputSession->setSessionParameters(sp);
}

- (BOOL) isEndState
{
    if((_tryToResumeFromOutside ||
        (self.rtmpSessionState != VCSessionStateError && self.rtmpSessionState != VCSessionStateUnstableNetwork)) &&
       self.rtmpSessionState != VCSessionStateEnded &&
       self.rtmpSessionState != VCSessionStateDisconnected) {
        
        return NO;
    }
    
    return YES;
}

- (void) saveVideoSource:(CVPixelBufferRef)pixelBufferRef
{
    _saveVideoSourceCount--;
    
    if(_saveVideoSourceCount <= 0){
        _saveVideoSourceCount = self.fps * 3;
        m_videoMixer->savePixelBuffer(pixelBufferRef);
    }
}

- (void) stopRtmpSession:(VCSessionState)state
{
    int delay = 4;
    
    [self invalidateStartSessionTimer];
    
    if(state == VCSessionStateEnded) {
        if(self.rtmpSessionState == VCSessionStateEnded)
            return;
        delay = 2;
    } else {
        if([self isEndState] == YES || _stopRtmpSession == YES)
            return;
    }
    
    _stopRtmpSession = YES;
    
    switch(state){
        case VCSessionStateEnded:
            DDLogInfo(@"changeVCSessionStateToEnded 1");
            break;
        case VCSessionStateError:
            DDLogInfo(@"changeVCSessionStateToError 1");
            break;
        case VCSessionStateDisconnected:
            DDLogInfo(@"changeVCSessionStateToDisconnected 1");
            break;
        case VCSessionStateUnstableNetwork:
            DDLogInfo(@"changeVCSessionStateToUnstableNetwork 1");
            break;
        default:
            DDLogInfo(@"Invalid state entered : %d", (int)state);
            return;
    }

    _blockVideoSource = YES;

    VCSimpleSession* bSelf = self;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if(state == VCSessionStateEnded) {
            if(bSelf.rtmpSessionState == VCSessionStateEnded)
                return;
        } else {
            if([bSelf isEndState] == YES || _endRtmpSession == YES)
                return;
        }

        switch(state){
            case VCSessionStateEnded:
                DDLogInfo(@"changeVCSessionStateToEnded 2");
                break;
            case VCSessionStateError:
                DDLogInfo(@"changeVCSessionStateToError 2");
                break;
            case VCSessionStateDisconnected:
                DDLogInfo(@"changeVCSessionStateToDisconnected 2");
                break;
            case VCSessionStateUnstableNetwork:
                DDLogInfo(@"changeVCSessionStateToUnstableNetwork 2");
                break;
            default:
                break;
        }
        
        _tryToResumeFromOutside = NO;
        bSelf.rtmpSessionState = state;
        [bSelf endRtmpSessionAndInitialize];
    });
}

- (void) endRtmpSessionAndInitialize
{
    DDLogInfo(@"endRtmpSessionAndInitialize");
    
    [self endRtmpSession];
    _blockVideoSource = NO;
    _isStartedRtmpSession = NO;
    _isCalledkClientStateSessionStarted = NO;
}

- (void) endRtmpSession
{
    DDLogInfo(@"endRtmpSession");
    
    [self invalidateStartSessionTimer];
    
    if(m_videoMixer) {
        m_videoMixer->mixPaused(true);
    }
    
    if(m_audioMixer) {
        m_audioMixer.reset();
        m_audioMixer = nil;
    }
    
    if(m_micSource) {
        m_micSource.reset();
        m_micSource = nil;
    }
    
    if(m_h264Packetizer) {
        m_h264Packetizer.reset();
        m_h264Packetizer = nil;
    }
    
    if(m_aacPacketizer) {
        m_aacPacketizer.reset();
        m_aacPacketizer = nil;
    }
    
    if(m_h264Encoder) {
        m_videoSplit->removeOutput(m_h264Encoder);
        m_h264Encoder.reset();
        m_h264Encoder = nil;
    }
    
    if(m_aacEncoder) {
        m_aacEncoder.reset();
        m_aacEncoder = nil;
    }
    
    if(m_outputSession) {
        m_outputSession.reset();
        m_outputSession = nil;
    }
    
    _bitrate = _bpsCeiling;
}

- (void) dealloc
{
    [self endRtmpSession];
    
    if(m_videoMixer) {
        m_videoMixer->mixPaused(true);
        m_videoMixer.reset();
        m_videoMixer = nil;
    }
    
    if(m_videoSplit) {
        m_videoSplit.reset();
    }
    
    if(m_cameraSource) {
        m_cameraSource.reset();
    }
    
//    if(_previewView) {
//        [_previewView release];
//        _previewView = nil;
//    }
    
    dispatch_release(_graphManagementQueue);
    
    [super dealloc];
}

- (void) setupGraph
{
    const double frameDuration = 1. / static_cast<double>(self.fps);

    {
        // Add audio mixer
        //const double aacPacketTime = 1024. / self.audioSampleRate;
/*
        m_audioMixer = std::make_shared<videocore::Apple::AudioMixer>(self.audioChannelCount,
                                                                      self.audioSampleRate,
                                                                      16,
                                                                      aacPacketTime);
*/


        // The H.264 Encoder introduces about 2 frames of latency, so we will set the minimum audio buffer duration to 2 frames.
        //m_audioMixer->setMinimumBufferDuration(frameDuration*2);
    }



    {
        // Add video mixer
        m_videoMixer = std::make_shared<videocore::iOS::GLESVideoMixer>(self.videoSize.width,
                                                                        self.videoSize.height,
                                                                        frameDuration);
        m_videoMixer->mixPaused(true);
    }

    {
        auto videoSplit = std::make_shared<videocore::Split>();

        m_videoSplit = videoSplit;

        m_videoMixer->setOutput(videoSplit);
    }


    {
        // Add mic source
        //m_micSource = std::make_shared<videocore::iOS::MicSource>(self.audioSampleRate, self.audioChannelCount);
        //m_micSource->setOutput(m_audioMixer);

        const auto epoch = std::chrono::steady_clock::now();

        //m_audioMixer->setEpoch(epoch);
        m_videoMixer->setEpoch(epoch);

        //m_audioMixer->start();
        m_videoMixer->start();

        _blockVideoSource = NO;
    }
}

- (void) addEncodersAndPacketizers
{
    const double frameDuration = 1. / static_cast<double>(self.fps);
    int ctsOffset = 2000 / self.fps; // 2 * frame duration
    
    {
        if(self.audioSampleRate != 48000) {
            // Add audio mixer
            const double aacPacketTime = 1024. / self.audioSampleRate;
            
            m_audioMixer = std::make_shared<videocore::Apple::AudioMixer>(self.audioChannelCount,
                                                                          self.audioSampleRate,
                                                                          16,
                                                                          aacPacketTime);
            
            
            
            // The H.264 Encoder introduces about 2 frames of latency, so we will set the minimum audio buffer duration to 2 frames.
            m_audioMixer->setMinimumBufferDuration(frameDuration*2);
        }
    }
    {
        // Add mic source
        m_micSource = std::make_shared<videocore::iOS::MicSource>(self.audioSampleRate, self.audioChannelCount);
        if(self.audioSampleRate != 48000) {
            m_micSource->setOutput(m_audioMixer);
            
            const auto epoch = std::chrono::steady_clock::now();
            
            m_videoMixer->setEpoch(epoch);
            
            m_audioMixer->setEpoch(epoch);
            
            m_audioMixer->start();
        }
        
        if(m_videoMixer)
            m_videoMixer->mixPaused(false);
    }
    {
        // Add encoders
        if(self.audioSampleRate != 48000) {
            m_aacEncoder = std::make_shared<videocore::iOS::AACEncode>(self.audioSampleRate, self.audioChannelCount, 128000);
            
            m_audioMixer->setOutput(m_aacEncoder);
        }
        
        m_h264Encoder = std::make_shared<videocore::Apple::H264Encode>(self.videoSize.width,
                                                                       self.videoSize.height,
                                                                       self.fps,
                                                                       self.bitrate,
                                                                       true,
                                                                       ctsOffset);

        m_videoSplit->setOutput(m_h264Encoder);

    }
    {
        m_aacSplit = std::make_shared<videocore::Split>();
        m_h264Split = std::make_shared<videocore::Split>();
        
        if(self.audioSampleRate != 48000) {
            m_aacEncoder->setOutput(m_aacSplit);
        } else {
            m_micSource->setOutput(m_aacSplit);
        }
        
        m_h264Encoder->setOutput(m_h264Split);

    }
    {
        m_h264Packetizer = std::make_shared<videocore::rtmp::H264Packetizer>(ctsOffset);
        
        m_aacPacketizer = std::make_shared<videocore::rtmp::AACPacketizer>(self.audioSampleRate, self.audioChannelCount, ctsOffset * 2);

        m_h264Split->setOutput(m_h264Packetizer);
        m_aacSplit->setOutput(m_aacPacketizer);

    }

    m_h264Packetizer->setOutput(m_outputSession);
    m_aacPacketizer->setOutput(m_outputSession);
}

-(UIImage *) getUIImageFromCVPixelBuffer:(CVPixelBufferRef) pixelBuffer
{
    if(pixelBuffer == nil) return nil;
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    GLubyte *dataTemp = (GLubyte *)CVPixelBufferGetBaseAddress(pixelBuffer);
    
    int height = (int) CVPixelBufferGetHeight(pixelBuffer);
    int width = (int) CVPixelBufferGetWidth(pixelBuffer);
    
    GLubyte *dataBuffer = (GLubyte *)malloc(width * height * 4);
    if(dataBuffer == NULL)
    {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }
    
    GLubyte *colorBuffer = (GLubyte *)malloc(width * height * 4);
    if(colorBuffer == NULL)
    {
        free(dataBuffer);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }
    
    memcpy(dataBuffer, dataTemp, width * height * 4);
    
    size_t bytesPerRow = width * 4;
    
    vImage_Buffer inbuff= {dataBuffer, (size_t)height, (size_t)width, bytesPerRow};
    
    vImage_Buffer outbuff = {colorBuffer, (size_t)height, (size_t)width, bytesPerRow};
    
    vImage_Error err;
    
    const uint8_t map[4] = { 2, 1, 0, 3 };
    
    
    err = vImagePermuteChannels_ARGB8888(&inbuff, &outbuff, map, kvImageNoFlags);
    if (err != kvImageNoError)
    {
        NSLog(@"vImagePermuteChannels error : %ld", err);
        free(dataBuffer);
        free(colorBuffer);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return nil;
    }
    
    size_t bufferSize = CVPixelBufferGetWidth(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer) * 4;
    NSData *data = [NSData dataWithBytes:outbuff.data length:bufferSize];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    
    int bitsPerComponent = 8;
    int bitsPerPixel = 32;
    bytesPerRow = 4 * (int)CVPixelBufferGetWidth(pixelBuffer);
    CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    CGImageRef imageRef = CGImageCreate(CVPixelBufferGetWidth(pixelBuffer),
                                        CVPixelBufferGetHeight(pixelBuffer),
                                        bitsPerComponent, bitsPerPixel,
                                        bytesPerRow, colorSpaceRef,
                                        bitmapInfo, provider,
                                        NULL, NO,
                                        renderingIntent);
    
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpaceRef);
    
    UIImage *tempImage = [UIImage imageWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    free(dataBuffer);
    free(colorBuffer);
    
    return tempImage;
}

@end
