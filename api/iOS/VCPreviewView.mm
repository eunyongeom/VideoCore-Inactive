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
#import "VCPreviewView.h"

#include <VideoCore/sources/iOS/GLESUtil.h>

#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#import <glm/glm.hpp>
#import <glm/gtc/matrix_transform.hpp>

#include <atomic>

@interface VCPreviewView()
{
    EAGLContext *_oglContext;
    GLuint _program;
    GLint _frame;
    
    CAEAGLLayer* _eaglLayer;
    CVOpenGLESTextureCacheRef _textureCache;
    GLint _width;
    GLint _height;
    GLuint _frameBufferHandle;
    GLuint _colorBufferHandle;
    GLuint _texture[2];

    CVOpenGLESTextureRef _exTextureRef[2];
    
    CVPixelBufferRef _currentRef[2];
    int _currentBuffer;
    
    CVPixelBufferRef _emptyPixelBuffer;
    std::atomic<bool> _paused;
    std::atomic<bool> _internalPaused;
    
    float drawX, drawY, drawHeight, drawWidth;
    int frameHeight, frameWidth;
}
@property (nonatomic, strong) EAGLContext* context;
@end
@implementation VCPreviewView

#if !defined(_STRINGIFY)
#define __STRINGIFY( _x )   # _x
#define _STRINGIFY( _x )   __STRINGIFY( _x )
#endif

static const char * kPassThruVertex = _STRINGIFY(
                                                 
                                                 attribute vec4 position;
                                                 attribute mediump vec4 texturecoordinate;
                                                 varying mediump vec2 coordinate;
                                                 uniform float zoom; // zoom
                                                 
                                                 void main()
{
    gl_Position = position;
    coordinate = texturecoordinate.xy;
    //zoom
    //coordinate = (coordinate - .5) * zoom + .5;
}
                                                 
                                                 );

static const char * kPassThruFragment = _STRINGIFY(
                                                   precision highp float;
                                                   varying highp vec2 coordinate;
                                                   uniform sampler2D videoframe;
                                                   //attribute vec4 tex;
                                                   void main()
{
    vec4 tex = texture2D ( videoframe, coordinate );
    gl_FragColor = vec4(tex.r, tex.g, tex.b, 0);
    //gl_FragColor = texture2D(videoframe, coordinate);
    //gl_FragColor = vec4(1, 0, 0, 1.0);
}
                                                   
                                                   );

enum {
    ATTRIB_VERTEX,
    ATTRIB_TEXTUREPOSITON,
    NUM_ATTRIBUTES
};


#pragma mark - UIView overrides

+ (Class) layerClass
{
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.contentScaleFactor = [UIScreen mainScreen].scale;
        _eaglLayer = (CAEAGLLayer*) self.layer;
        
        _eaglLayer.opaque = YES;
        
        _eaglLayer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO,kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
        _eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES],kEAGLDrawablePropertyRetainedBacking,kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,nil];
        
        
        EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES3;
        self.context = [[EAGLContext alloc] initWithAPI:api];
        if (!self.context) {
            NSLog(@"Failed to initialize OpenGLES 2.0 context");
            exit(1);
        }
        
        if (![EAGLContext setCurrentContext:self.context]) {
            NSLog(@"Failed to set current OpenGL context");
            exit(1);
        }
        
        _oglContext = self.context;
        GLuint _framebuffer;
        GLuint _colorRenderBuffer;
        glGenFramebuffers(1, &_framebuffer);
        glGenRenderbuffers(1, &_colorRenderBuffer);
        
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderBuffer);
        
        
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderBuffer);
        
        self.autoresizingMask = 0xFF;
    }
    return self;
}
- (instancetype) init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:UIApplicationWillEnterForegroundNotification object:nil];
        
        int width = 1440;
        int height = 720;
        
        NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                              (NSString*) kCVPixelBufferWidthKey : @(width),
                                              (NSString*) kCVPixelBufferHeightKey : @(height),
                                              (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                              (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
        
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (CFDictionaryRef)pixelBufferOptions, &_emptyPixelBuffer);
    }
    return self;
}
//- (void) awakeFromNib {
//    NSLog(@"%s %d", __PRETTY_FUNCTION__, __LINE__);
//    [super awakeFromNib];
//    [self initInternal];
//}
//- (void) initInternal {
//    NSLog(@"%s %d", __PRETTY_FUNCTION__, __LINE__);
//     self.autoresizingMask = 0xFF;
//    
//}
- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self reset];
    
    
    if(_emptyPixelBuffer) {
        CVPixelBufferRelease(_emptyPixelBuffer);
    }
//    if ( _framebuffer ) {
//        glDeleteFramebuffers( 1, &_framebuffer );
//        _framebuffer = 0;
//    }
//    if ( _colorRenderBuffer ) {
//        glDeleteRenderbuffers( 1, &_colorRenderBuffer );
//        _colorRenderBuffer = 0;
//    }
//    
    self.context = nil;
    
    [super dealloc];
}
- (void) layoutSubviews
{
    self.backgroundColor = [UIColor blackColor];
    
//    glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_width );
//    glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_height );
//    
//    NSLog(@"%s %d layoutSubviews _width :%d &  _height %d",__PRETTY_FUNCTION__, __LINE__, _width, _height );
}

- (void) notification: (NSNotification*) notification
{
    if([notification.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        _internalPaused = true;
    } else if([notification.name isEqualToString:UIApplicationWillEnterForegroundNotification]) {
        _internalPaused = false;
    }
}

- (void) startPreview
{
    NSLog(@"%s %d ViewPort: X: %f Y: %f W: %f H: %f", __PRETTY_FUNCTION__, __LINE__, drawX, drawY, drawWidth, drawHeight );
    _paused = false;
}

- (void) stopPreview
{
    NSLog(@"%s %d ViewPort: X: %f Y: %f W: %f H: %f", __PRETTY_FUNCTION__, __LINE__, drawX, drawY, drawWidth, drawHeight );
    [self drawFrame:_emptyPixelBuffer isEmptyPixelBuffer:YES];
    _paused = true;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self reset];
    });
}

- (void) prepareForRotationPreview
{
    [self drawFrame:_emptyPixelBuffer isEmptyPixelBuffer:YES];
    _internalPaused = true;
    [self reset];
}

- (void) completionRotationPreview
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        _internalPaused = false;
    });
}

#pragma mark - Public Methods

- (void) drawFrame:(CVPixelBufferRef)pixelBuffer isEmptyPixelBuffer:(BOOL)isEmptyPixelBuffer
{
    if(pixelBuffer == nil || (_paused == true && !isEmptyPixelBuffer))
        return;
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f, // bottom left
        1.0f, -1.0f, // bottom right
        -1.0f,  1.0f, // top left
        1.0f,  1.0f, // top right
    };
    
    
    bool updateTexture = false;
    
    if(pixelBuffer != _currentRef[_currentBuffer]) {
        // not found, swap buffers.
        _currentBuffer = !_currentBuffer;
    }
    
    if(pixelBuffer != _currentRef[_currentBuffer]) {
        // Still not found, update the texture for this buffer.
        if(_currentRef[_currentBuffer]){
            CVPixelBufferRelease(_currentRef[_currentBuffer]);
        }
        
        _currentRef[_currentBuffer] = CVPixelBufferRetain(pixelBuffer);
        updateTexture = true;
        
    }
    int currentBuffer = _currentBuffer;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        if(_paused == true && !isEmptyPixelBuffer)
            return;
        
        EAGLContext *oldContext = [EAGLContext currentContext];
        if ( oldContext != _oglContext ) {
            if ( ! [EAGLContext setCurrentContext:_oglContext] ) {
                @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem with OpenGL context" userInfo:nil];
                
                return;
            }
        }
        if ( _frameBufferHandle == 0 ) {
            BOOL success = [self initializeBuffers];
            if ( ! success ) {
                NSLog(@"Problem initializing OpenGL buffers." );
                if ( oldContext != _oglContext ) {
                    [EAGLContext setCurrentContext:oldContext];
                }
                return;
            }
            
            GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if(status != GL_FRAMEBUFFER_COMPLETE)
                NSLog(@"%s %d Framebuffer status: %x",__PRETTY_FUNCTION__,__LINE__, (int)status);
        }
        
        if(_internalPaused == true  && !isEmptyPixelBuffer)
        {
            if ( oldContext != _oglContext ) {
                [EAGLContext setCurrentContext:oldContext];
            }
            return;
        }
        
        if(_texture[0] == 0)
        {
            glGenTextures(2, _texture);
        }
        
        if(updateTexture)
        {
            if(_exTextureRef[currentBuffer])
            {
                CFRelease(_exTextureRef[currentBuffer]);
            }
            
            CVPixelBufferLockBaseAddress(_currentRef[_currentBuffer], kCVPixelBufferLock_ReadOnly);
            frameWidth = (int) CVPixelBufferGetWidth(_currentRef[_currentBuffer]);
            frameHeight = (int) CVPixelBufferGetHeight(_currentRef[_currentBuffer]);
            GLubyte *dataTemp = (GLubyte *)CVPixelBufferGetBaseAddress(_currentRef[_currentBuffer]);
            
            checkGlErrorLB("1");
            
            glBindTexture(GL_TEXTURE_2D, _texture[currentBuffer]);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, frameWidth, frameHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, dataTemp);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
            checkGlErrorLB("2 0");
            //_texture = CVOpenGLESTextureGetName(_exTextureRef[0]);
            glBindTexture(GL_TEXTURE_2D,_texture[currentBuffer]);
            
            checkGlErrorLB("2 1");
        
            CVPixelBufferUnlockBaseAddress(_currentRef[_currentBuffer], kCVPixelBufferLock_ReadOnly);
        }
        
        glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_width );
        glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_height );
        
        //NSLog(@"%s %d GLView: initializeBuffers _width :%d &  _height %d",__PRETTY_FUNCTION__, __LINE__, _width, _height );
        
        
        drawWidth = _width;
        
        drawHeight = (drawWidth / frameWidth) * frameHeight;
        
        drawX = 0;
        drawY = _height/2 - drawHeight/2;
        
        //NSLog(@"ViewPort: X: %f Y: %f W: %f H: %f", drawX, drawY, drawWidth, drawHeight );
        
        glViewport( drawX, drawY, drawWidth, drawHeight);
        
        
        
        glBindFramebuffer(GL_FRAMEBUFFER, _frameBufferHandle);
        glClear(GL_COLOR_BUFFER_BIT);
        checkGlErrorLB("3");
        
        //glViewport(0, 0, _width, _height);
        glUseProgram( _program );
        glActiveTexture( GL_TEXTURE0 );
        
        glUniform1i( _frame, 0 );
        checkGlErrorLB("4");
        
        
        // Set texture parameters
        glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
        glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
        glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
        glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
        
        glVertexAttribPointer( ATTRIB_VERTEX, 2, GL_FLOAT, 0, 0, squareVertices );
        glEnableVertexAttribArray( ATTRIB_VERTEX );
        
        checkGlErrorLB("5");
        
        //NSLog(@"Bound W:%f H:%f",self.bounds.size.width,  self.bounds.size.height);
        
        GLfloat passThroughTextureVerticesNoScale[] = {
            0.0f, 1.0f,
            1.0f,  1.0f,
            0.0f,  0.0f,
            1.0f, 0.0f,
        };
        
        checkGlErrorLB("7");
        glVertexAttribPointer( ATTRIB_TEXTUREPOSITON, 2, GL_FLOAT, 0, 0, passThroughTextureVerticesNoScale );
        glEnableVertexAttribArray( ATTRIB_TEXTUREPOSITON );
        glDrawArrays( GL_TRIANGLE_STRIP, 0, 4 );
        checkGlErrorLB("8");
        glFinish();
        glBindFramebuffer( GL_FRAMEBUFFER, _frameBufferHandle );
        glBindTexture( GL_TEXTURE_2D, 0 );
        checkGlErrorLB("6");
        
        [_oglContext presentRenderbuffer:GL_RENDERBUFFER];
        
        CVOpenGLESTextureCacheFlush(_textureCache,0);
        
        glBindTexture( GL_TEXTURE_2D, 0 );
        //CFRelease( texture );
        
        if ( oldContext != _oglContext ) {
            [EAGLContext setCurrentContext:oldContext];
        }
        
    });
}
#pragma mark - Private Methods

- (BOOL)initializeBuffers
{
    BOOL success = YES;
    
    glDisable( GL_DEPTH_TEST );
    
    glGenFramebuffers( 1, &_frameBufferHandle );
    glBindFramebuffer( GL_FRAMEBUFFER, _frameBufferHandle );
    
    glGenRenderbuffers( 1, &_colorBufferHandle );
    glBindRenderbuffer( GL_RENDERBUFFER, _colorBufferHandle );
    
    [_oglContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    
    glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_width );
    glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_height );
    
    NSLog(@"%s %d GLView: initializeBuffers _width :%d &  _height %d",__PRETTY_FUNCTION__, __LINE__, _width, _height );
    
   
    glFramebufferRenderbuffer( GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorBufferHandle );
    
    
    if ( glCheckFramebufferStatus( GL_FRAMEBUFFER ) != GL_FRAMEBUFFER_COMPLETE ) {
        NSLog(@"GLView: Failure with framebuffer generation" );
        success = NO;
        if ( ! success ) {
            [self reset];
        }
        return success;
    }
    
    //  Create a new CVOpenGLESTexture cache
    CVReturn err = CVOpenGLESTextureCacheCreate( kCFAllocatorDefault, NULL, _oglContext, NULL, &_textureCache );
    if ( err ) {
        NSLog(@"GLView: Error at CVOpenGLESTextureCacheCreate %d", err );
        success = NO;
        if ( ! success ) {
            [self reset];
        }
        return success;
    }
    
    // attributes
    GLint attribLocation[NUM_ATTRIBUTES] = {
        ATTRIB_VERTEX, ATTRIB_TEXTUREPOSITON,
    };
    GLchar *attribName[NUM_ATTRIBUTES] = {
        "position", "texturecoordinate",
    };
    
    glueCreateProgram( kPassThruVertex, kPassThruFragment,
                      NUM_ATTRIBUTES, (const GLchar **)&attribName[0], attribLocation,
                      0, 0, 0,
                      &_program );
    
    if ( ! _program ) {
        NSLog( @"GLView: Error creating the program" );
        success = NO;
        if ( ! success ) {
            [self reset];
        }
        return success;
    }
    
    _frame = glueGetUniformLocation( _program, "videoframe" );
    
    if ( ! success ) {
        [self reset];
    }
    
    
    //for view port of output display
    NSLog( @"GLView: _width :%d &  _height %d", _width, _height );
    

    glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_width );
    glGetRenderbufferParameteriv( GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_height );
    
    
    _currentRef [0] = _currentRef[1] = nil;
    _currentBuffer = 1;
    
    

    
    
    _internalPaused = false;
    return success;
}
- (void)reset
{
    NSLog(@"%s %d ViewPort: X: %f Y: %f W: %f H: %f", __PRETTY_FUNCTION__, __LINE__, drawX, drawY, drawWidth, drawHeight );
    
    EAGLContext *oldContext = [EAGLContext currentContext];
    if ( oldContext != _oglContext ) {
        if ( ! [EAGLContext setCurrentContext:_oglContext] ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Problem with OpenGL context" userInfo:nil];
            return;
        }
    }
    if ( _frameBufferHandle ) {
        glDeleteFramebuffers( 1, &_frameBufferHandle );
        _frameBufferHandle = 0;
    }
    if ( _colorBufferHandle ) {
        glDeleteRenderbuffers( 1, &_colorBufferHandle );
        _colorBufferHandle = 0;
    }
    if ( _program ) {
        glDeleteProgram( _program );
        _program = 0;
    }
    if ( _textureCache ) {
        CFRelease( _textureCache );
        _textureCache = 0;
    }
    
//    if(_emptyPixelBuffer) {
//        CVPixelBufferRelease(_emptyPixelBuffer);
//    }
    if(_exTextureRef[0]) {
        CFRelease(_exTextureRef[0]);
    }
    if(_exTextureRef[1]) {
        CFRelease(_exTextureRef[1]);
    }
//    if(_currentRef[0]) {
//        CVPixelBufferRelease(_currentRef[0]);
//    }
//    if(_currentRef[1]) {
//        CVPixelBufferRelease(_currentRef[1]);
//    }
    
    if ( oldContext != _oglContext && !_paused) {
        [EAGLContext setCurrentContext:oldContext];
    }
}
@end
