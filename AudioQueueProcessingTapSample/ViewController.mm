//
//  ViewController.m
//  AudioQueueProcessingTapSample
//
//  Created by Tamás Zahola on 2018. 10. 07..
//  Copyright © 2018. Tamás Zahola. All rights reserved.
//

#import "ViewController.h"

#import <vector>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define check(x) do {\
    OSStatus __status = (x);\
    NSCAssert(__status == noErr, @"OSStatus error: %lld", (long long)__status);\
} while(0)

static void AudioQueueCallback(void * __nullable inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);
static void ProcessingTapCallback(void * inClientData,
                                  AudioQueueProcessingTapRef inAQTap,
                                  UInt32 inNumberFrames,
                                  AudioTimeStamp * ioTimeStamp,
                                  AudioQueueProcessingTapFlags * ioFlags,
                                  UInt32 * outNumberFrames,
                                  AudioBufferList * ioData);

@implementation ViewController {
    @public
    AudioFileID _file;
    AudioStreamBasicDescription _asbd;
    SInt64 _nextPacket;
    AudioQueueRef _queue;
    AudioQueueTimelineRef _timeline;
    std::vector<AudioQueueBufferRef> _buffers;
    AudioQueueProcessingTapRef _processingTap;
    
    BOOL _playing;
    NSTimer* _playbackTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    AVAudioSession* session = AVAudioSession.sharedInstance;
    NSError* error;
    BOOL didSet = [session setCategory:AVAudioSessionCategoryPlayback
                                  mode:AVAudioSessionModeDefault
                    routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongForm
                               options:0
                                 error:&error];
    NSAssert(didSet, @"%@", error);
    
    didSet = [session setActive:YES withOptions:0 error:&error];
    NSAssert(didSet, @"%@", error);
    
    NSURL* url = [NSBundle.mainBundle URLForResource:@"piano_48k" withExtension:@"aiff"]; // <--- change this to "piano_44.1k"
    NSAssert(url != nil, @"");
    check(AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, kAudioFileAIFFType, &_file));
    _nextPacket = 0;
    
    UInt32 asbdSize = sizeof(_asbd);
    check(AudioFileGetProperty(_file, kAudioFilePropertyDataFormat, &asbdSize, &_asbd));
    
    check(AudioQueueNewOutput(&_asbd, AudioQueueCallback, (__bridge void*)self, CFRunLoopGetCurrent(), NULL, 0, &_queue));
    check(AudioQueueCreateTimeline(_queue, &_timeline));
    
    NSTimeInterval const bufferDuration = 1;
    UInt32 const bufferSize = bufferDuration * _asbd.mSampleRate * _asbd.mBytesPerFrame;
    for (auto i = 0; i < 3; ++i) {
        AudioQueueBufferRef buffer;
        check(AudioQueueAllocateBuffer(_queue, bufferSize, &buffer));
        _buffers.push_back(buffer);
    }
    
    [self setupTap]; // <--- remove this line to disable processing tap
    
    for (auto buffer : _buffers) {
        AudioQueueCallback((__bridge void*)self, _queue, buffer);
    }
}

- (void)setupTap {
    UInt32 maxFrames;
    AudioStreamBasicDescription tapASBD;
    check(AudioQueueProcessingTapNew(_queue,
                                     ProcessingTapCallback,
                                     (__bridge void*)self,
                                     kAudioQueueProcessingTap_PostEffects,
                                     &maxFrames,
                                     &tapASBD,
                                     &_processingTap));
}

- (IBAction)play:(UIButton*)sender {
    if (_playing) {
        check(AudioQueuePause(_queue));
        [_playbackTimer invalidate];
        _playbackTimer = nil;
    } else {
        check(AudioQueueStart(_queue, NULL));
        
        typeof(self) __weak weakSelf = self;
        _playbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            typeof(self) __strong strongSelf = weakSelf;
            
            Boolean discontinuityOccured;
            AudioTimeStamp timestamp;
            check(AudioQueueGetCurrentTime(strongSelf->_queue, strongSelf->_timeline, &timestamp, &discontinuityOccured));
            NSLog(@"%f %@", timestamp.mSampleTime / strongSelf->_asbd.mSampleRate, discontinuityOccured ? @"discontinuity occured!" : @"");
        }];
    }
    _playing = !_playing;
    [sender setTitle:_playing ? @"Pause" : @"Play" forState:UIControlStateNormal];
}

@end

static void AudioQueueCallback(void * __nullable inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    ViewController __unsafe_unretained * self = (__bridge ViewController __unsafe_unretained *)inUserData;
    
    UInt32 size = inBuffer->mAudioDataBytesCapacity;
    UInt32 packets = size / self->_asbd.mBytesPerFrame;
    OSStatus status = AudioFileReadPacketData(self->_file, false, &size, NULL, self->_nextPacket, &packets, inBuffer->mAudioData);
    if (status == kAudioFileEndOfFileError || size == 0) {
        self->_nextPacket = 0;
        AudioQueueCallback(inUserData, inAQ, inBuffer); // quick n dirty infinite looper
    } else {
        check(status);
        
        self->_nextPacket += packets;
        inBuffer->mAudioDataByteSize = size;
        
        check(AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL));
    }
}

static void ProcessingTapCallback(void * inClientData,
                                  AudioQueueProcessingTapRef inAQTap,
                                  UInt32 inNumberFrames,
                                  AudioTimeStamp * ioTimeStamp,
                                  AudioQueueProcessingTapFlags * ioFlags,
                                  UInt32 * outNumberFrames,
                                  AudioBufferList * ioData) {
    check(AudioQueueProcessingTapGetSourceAudio(inAQTap, inNumberFrames, ioTimeStamp, ioFlags, outNumberFrames, ioData));
    NSCAssert(inNumberFrames == *outNumberFrames, @"%d vs %d", (int)inNumberFrames, (int)*outNumberFrames);
}
