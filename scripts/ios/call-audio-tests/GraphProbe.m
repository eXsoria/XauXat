#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Diagnostic only: reproduce the live input graph and capture AVFAudio's
// Objective-C exception reason instead of losing it at Swift's error boundary.
@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) NSMutableDictionary *result;
@property(nonatomic, strong) NSString *caseName;
@end

@implementation ProbeApp
- (void)save {
    NSURL *dir = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[dir URLByAppendingPathComponent:[self.caseName stringByAppendingString:@".json"]] atomically:YES];
}
- (void)probe {
    self.result = [NSMutableDictionary dictionaryWithDictionary:@{@"case":self.caseName, @"stage":@"session"}];
    @try {
        NSError *error = nil;
        BOOL voice = [self.caseName hasSuffix:@"-voice"];
        AVAudioSession *session = AVAudioSession.sharedInstance;
        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:voice ? AVAudioSessionModeVoiceChat : AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error]
            || ![session setActive:YES error:&error]) {
            self.result[@"error"] = error.localizedDescription;
            [self save]; return;
        }
        self.result[@"stage"] = @"graph";
        AVAudioEngine *engine = [AVAudioEngine new]; self.engine = engine;
        if (voice && ![engine.outputNode setVoiceProcessingEnabled:YES error:&error]) {
            self.result[@"error"] = error.localizedDescription;
            [self save]; return;
        }
        engine.outputNode.AUAudioUnit.inputEnabled = YES;
        engine.outputNode.AUAudioUnit.outputEnabled = YES;
        AVAudioFormat *input = [engine.inputNode outputFormatForBus:0];
        AVAudioFormat *output = [engine.outputNode outputFormatForBus:0];
        self.result[@"input"] = input.description;
        self.result[@"output"] = output.description;
        if (input.sampleRate <= 0 || input.channelCount == 0 || output.sampleRate <= 0 || output.channelCount == 0) {
            self.result[@"error"] = @"No usable simulator audio route";
            [self save]; return;
        }
        BOOL tap = [self.caseName hasPrefix:@"tap-"];
        BOOL pitch = ![self.caseName hasPrefix:@"direct"];
        AVAudioUnitTimePitch *effect = pitch ? [AVAudioUnitTimePitch new] : nil;
        if (effect) {
            effect.pitch = 0; effect.rate = 1;
            [engine attachNode:effect];
            if ([self.caseName containsString:@"mixer-pitch"]) {
                AVAudioMixerNode *inputMixer = [AVAudioMixerNode new];
                [engine attachNode:inputMixer];
                [engine connect:engine.inputNode to:inputMixer format:input];
                [engine connect:inputMixer to:effect format:input];
            } else {
                [engine connect:engine.inputNode to:effect format:[self.caseName containsString:@"native-pitch"] ? nil : input];
            }
        }
        if (tap) {
            AVAudioMixerNode *muted = [AVAudioMixerNode new]; muted.outputVolume = 0;
            [engine attachNode:muted];
            [engine connect:effect to:muted format:input];
            [engine connect:muted to:engine.mainMixerNode format:input];
            [effect installTapOnBus:0 bufferSize:480 format:input block:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {}];
        } else {
            AVAudioSinkNode *sink = [[AVAudioSinkNode alloc] initWithReceiverBlock:^OSStatus(const AudioTimeStamp *time, AVAudioFrameCount frames, const AudioBufferList *buffers) { return noErr; }];
            [engine attachNode:sink];
            [engine connect:effect ?: engine.inputNode to:sink format:input];
        }
        // Match WebRTC's independent, silent playout branch.
        AVAudioFormat *rtc = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:output.sampleRate channels:output.channelCount interleaved:YES];
        AVAudioSourceNode *source = [[AVAudioSourceNode alloc] initWithFormat:rtc renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *buffers) {
            for (UInt32 i=0; i<buffers->mNumberBuffers; i++) if (buffers->mBuffers[i].mData) memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
            *silence = YES; return noErr;
        }];
        [engine attachNode:source];
        [engine connect:source to:engine.mainMixerNode format:output];
        [engine connect:engine.mainMixerNode to:engine.outputNode format:output];
        self.result[@"stage"] = @"prepare";
        [engine prepare];
        self.result[@"stage"] = @"start";
        if (![engine startAndReturnError:&error]) { self.result[@"error"] = error.localizedDescription; [self save]; return; }
        [engine stop];
        self.result[@"stage"] = @"reprepare";
        [engine prepare];
        self.result[@"stage"] = @"passed";
    } @catch (NSException *exception) {
        self.result[@"exception"] = exception.name;
        self.result[@"reason"] = exception.reason ?: @"";
    }
    [self save];
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.caseName = NSProcessInfo.processInfo.arguments.lastObject;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/2), dispatch_get_main_queue(), ^{ [self probe]; });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class)); }
}
