//
//  Xtrace.h
//  Xtrace
//
//  Created by John Holdsworth on 28/02/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  Repo: https://github.com/johnno1962/Xtrace
//
//  $Id: //depot/Xtrace/Xray/Xtrace.h#14 $
//
//  Class to intercept messages sent to a class or object.
//  Swizzles generic logging implemntation in place of the
//  original which is called after logging the message.
//
//  Implemented as category  on NSObject so message the
//  class or instance you want to log for example:
//
//  Log all messages of the navigation controller class
//  and it's superclasses:
//  [UINavigationController xtrace]
//
//  Log all messages sent to objects instance1/2
//  [instance1 xtrace];
//  [instance2 xtrace];
//
//  Instance tracing takes priority.
//

#ifdef DEBUG
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface NSObject(Xtrace)

// avoid a class
+ (void)notrace;

// trace class or..
+ (void)xtrace;

// trace instance
- (void)xtrace;

// stop tacing "
- (void)untrace;

@end

// implementing class
@interface Xtrace : NSObject

// delegate for callbacks
+ (void)setDelegate:delegate;

// hide log of return values
+ (void)hideReturns:(BOOL)hide;

// attempt log of call arguments
+ (void)showArguments:(BOOL)show;

// log values's "description"
+ (void)describeValues:(BOOL)desc;

// property methods filtered out by default
+ (void)includeProperties:(BOOL)include;

// include/exclude methods matching pattern
+ (BOOL)includeMethods:(NSString *)pattern;
+ (BOOL)excludeMethods:(NSString *)pattern;
+ (BOOL)excludeTypes:(NSString *)pattern;

// don't trace this class e.g. [UIView notrace]
+ (void)dontTrace:(Class)aClass;

// trace class down to NSObject
+ (void)traceClass:(Class)aClass;

// trace class down to "levels" of superclases
+ (void)traceClass:(Class)aClass levels:(int)levels;

// trace all messages sent to an instance
+ (void)traceInstance:(id)instance;

// stop tracing messages to instance
+ (void)untrace:(id)instance;

// before, replacement and after callbacks
+ (void)forClass:(Class)aClass before:(SEL)sel callback:(SEL)callback;
+ (void)forClass:(Class)aClass replace:(SEL)sel callback:(SEL)callback;
+ (void)forClass:(Class)aClass after:(SEL)sel callback:(SEL)callback;

// internal information
#define XTRACE_ARGS_SUPPORTED 10

typedef void (*VIMP)( id obj, SEL sel, ... );

struct _xtrace_arg {
    const char *name, *type;
    int stackOffset;
};

// information about original implementations
struct _xtrace_info {
    int depth;
    Method method;
    VIMP before, original, after;
    const char *name, *type, *mtype;
    struct _xtrace_arg args[XTRACE_ARGS_SUPPORTED+1];

    void *lastObj;
    struct _stats {
        NSTimeInterval entered, elapsed;
        unsigned callCount;
    } stats;
    BOOL logged, callingBack;
};

// includes argument info and recorded stats
+ (struct _xtrace_info *)infoFor:(Class)aClass sel:(SEL)sel;

@end
#endif
#endif
