#import "audio_engine_exception_boundary.h"

static NSString *const HCAudioEngineErrorDomain =
    @"com.longdevity.hardwarecontroller.audio_engine";
static NSString *const HCAudioEngineExceptionNameKey = @"exception_name";

/// Converts one framework exception into a stable local error.
static NSError *HCAudioEngineError(NSException *exception, NSInteger code,
                                   NSString *fallbackDescription) {
  NSString *description = exception.reason ?: fallbackDescription;
  return [NSError errorWithDomain:HCAudioEngineErrorDomain
                             code:code
                         userInfo:@{
                           NSLocalizedDescriptionKey : description,
                           HCAudioEngineExceptionNameKey : exception.name
                         }];
}

@implementation HCAudioEngineExceptionBoundary

/// Installs one tap while containing AVFAudio's Objective-C exceptions.
+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat *_Nullable)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError *_Nullable *_Nullable)error {
  @try {
    [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error =
          HCAudioEngineError(exception, 1, @"AVFAudio rejected the input tap.");
    }
    return NO;
  }
}

/// Removes one tap while containing AVFAudio's Objective-C exceptions.
+ (BOOL)removeTapFromNode:(AVAudioNode *)node
                      bus:(AVAudioNodeBus)bus
                    error:(NSError *_Nullable *_Nullable)error {
  @try {
    [node removeTapOnBus:bus];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error = HCAudioEngineError(exception, 2,
                                  @"AVFAudio rejected input tap removal.");
    }
    return NO;
  }
}

/// Prepares one engine while containing AVFAudio's Objective-C exceptions.
+ (BOOL)prepareEngine:(AVAudioEngine *)engine
                error:(NSError *_Nullable *_Nullable)error {
  @try {
    [engine prepare];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error = HCAudioEngineError(exception, 3,
                                  @"AVFAudio rejected engine preparation.");
    }
    return NO;
  }
}

/// Starts one engine while containing AVFAudio's Objective-C exceptions.
+ (BOOL)startEngine:(AVAudioEngine *)engine
              error:(NSError *_Nullable *_Nullable)error {
  @try {
    return [engine startAndReturnError:error];
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error =
          HCAudioEngineError(exception, 4, @"AVFAudio rejected engine start.");
    }
    return NO;
  }
}

/// Stops one engine while containing AVFAudio's Objective-C exceptions.
+ (BOOL)stopEngine:(AVAudioEngine *)engine
             error:(NSError *_Nullable *_Nullable)error {
  @try {
    [engine stop];
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      *error =
          HCAudioEngineError(exception, 5, @"AVFAudio rejected engine stop.");
    }
    return NO;
  }
}

@end
