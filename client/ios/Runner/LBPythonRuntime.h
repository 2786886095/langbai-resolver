#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LBPythonRuntime : NSObject

+ (instancetype)sharedRuntime;

- (BOOL)initializeRuntime:(NSError **)error;

- (nullable NSString *)callFunction:(NSString *)functionName
                       jsonArgument:(NSString *)jsonArgument
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
