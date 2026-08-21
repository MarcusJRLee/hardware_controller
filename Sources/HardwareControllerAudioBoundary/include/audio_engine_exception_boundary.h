#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts AVFAudio graph exceptions into NSError values.
@interface HCAudioEngineExceptionBoundary : NSObject

/// Installs one tap or returns a typed error without unwinding into Swift.
+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(nullable AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError *_Nullable *_Nullable)error;

/// Removes one tap or returns a typed error without unwinding into Swift.
+ (BOOL)removeTapFromNode:(AVAudioNode *)node
                      bus:(AVAudioNodeBus)bus
                    error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(removeTap(from:bus:));

/// Prepares one engine or returns a typed error without unwinding into Swift.
+ (BOOL)prepareEngine:(AVAudioEngine *)engine
                error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(prepare(_:));

/// Starts one engine or returns a typed error without unwinding into Swift.
+ (BOOL)startEngine:(AVAudioEngine *)engine
              error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(start(_:));

/// Stops one engine or returns a typed error without unwinding into Swift.
+ (BOOL)stopEngine:(AVAudioEngine *)engine
             error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(stop(_:));

@end

NS_ASSUME_NONNULL_END
