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

/*!
 *  A simple Objective-C Session API that will create an RTMP session using the
 *  device's camera(s) and microphone.
 *
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@class VCSimpleSession;

typedef NS_ENUM(NSInteger, VCSessionState)
{
    VCSessionStateNone,
    VCSessionStateStarting,
    VCSessionStateStarted,
    VCSessionStateEnded,
    VCSessionStateError,
    VCSessionStateResumed,
    VCSessionStateUnstableNetwork,
    VCSessionStateDisconnected
};

@protocol VCSessionDelegate <NSObject>
@required
- (void) connectionStatusChanged:(VCSessionState) sessionState capturedImage:(UIImage *)capturedImage;
- (void) weakSignalDetected;
@optional
- (void) detectedThroughput: (NSInteger) throughputInBytesPerSecond; //Depreciated, should use method below
- (void) detectedThroughput: (NSInteger) throughputInBytesPerSecond videoRate:(NSInteger) rate;
@end

@interface VCSimpleSession : NSObject

@property (nonatomic, readonly) VCSessionState rtmpSessionState;
//@property (nonatomic, strong, readonly) UIView* previewView;

/*! Setters / Getters for session properties */
@property (nonatomic, assign) CGSize            videoSize;      // Change will not take place until the next RTMP Session
@property (nonatomic, assign) int               bitrate;        // Change will not take place until the next RTMP Session
@property (nonatomic, assign) int               fps;            // Change will not take place until the next RTMP Session
@property (nonatomic, assign, readonly) BOOL    useInterfaceOrientation;
@property (nonatomic, assign) int           audioChannelCount;
@property (nonatomic, assign) float         audioSampleRate;
@property (nonatomic, assign) float         micGain;        // [0..1]
@property (nonatomic, assign) BOOL          useAdaptiveBitrate;     /* Default is off */
@property (nonatomic, readonly) int         estimatedThroughput;    /* Bytes Per Second. */

@property (nonatomic, assign) id<VCSessionDelegate> delegate;

+ (instancetype) sharedInstance;

- (void) startRtmpSessionWithURL:(NSString*) rtmpUrl;

- (void) resumeRtmpSessionWithURL:(NSString*) rtmpUrl;

- (void) endRtmpSessionAndCaptureImage;

- (void) pushVideoBuffer:(CVPixelBufferRef)pixelBufferRef width:(int)width height:(int)height timeStamp:(long)timeStamp;

- (void) pushAudioBuffer:(NSData *)frame timeStamp:(long)timeStamp;

- (void) startPreview;

- (void) stopPreview;

- (void) prepareForRotationPreview;

- (void) completionRotationPreview;

/*!
 *  Note that the rect you provide should be based on your video dimensions.  The origin
 *  of the image will be the center of the image (so if you put 0,0 as its position, it will
 *  basically end up with the bottom-right quadrant of the image hanging out at the top-left corner of
 *  your video)
 */

@end
