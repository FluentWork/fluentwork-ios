#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting an Objective-C exception into an `NSError`.
///
/// Swift cannot catch `NSException`. Several AVFoundation calls **raise** rather
/// than return an error — `AVAudioPlayerNode.play()` is one, and it does so when
/// the node has no engine to play into, which is not a state it reports.
///
/// Such a call is unrecoverable from Swift: the only options are to predict when
/// it will raise, or to catch it here. Prediction was tried repeatedly and
/// failed on device every time; this is the backstop.
///
/// Returns `YES` when `block` returned without raising.
///
/// `NS_NOESCAPE` so Swift sees a non-escaping closure: the call is synchronous
/// and stays on the caller's executor, which is what lets it be called from an
/// actor method without the isolation dance.
FOUNDATION_EXPORT BOOL FWTryCatch(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
