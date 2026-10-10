#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCGreeter : NSObject

@property (nonatomic, copy, readonly) NSString *name;

- (instancetype)initWithName:(NSString *)name;
- (NSString *)greetingForTimes:(NSInteger)times;

@end

NS_ASSUME_NONNULL_END
