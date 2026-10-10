#import "ObjCLib.h"

@implementation ObjCGreeter

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _name = [name copy];
    }
    return self;
}

- (NSString *)greetingForTimes:(NSInteger)times {
    return [NSString stringWithFormat:@"Hello %@ x%ld", self.name, (long)times];
}

@end
